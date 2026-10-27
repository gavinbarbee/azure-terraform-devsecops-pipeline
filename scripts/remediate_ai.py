"""Turn failed Checkov checks into AI remediation suggestions on the pull request.

Runs in the ai-remediation job after the Checkov gate fails. It reads the real
Checkov JSON output, de-duplicates findings by check ID, asks the Azure OpenAI
deployment for a fix for each one, and posts (or updates) a single PR comment.

Authentication is keyless: the job signs in to Azure with GitHub OIDC, and this
script requests an Entra ID token for Azure OpenAI from that session. The OpenAI
account has local (API key) auth disabled.
"""

import json
import os
import sys
import time

import requests
from azure.identity import AzureCliCredential, get_bearer_token_provider
from openai import AzureOpenAI

RESULTS_FILE = "checkov-results.json"
MAX_FINDINGS = 5
API_VERSION = "2024-10-21"
COMMENT_MARKER = "<!-- ai-remediation -->"
GITHUB_API = "https://api.github.com"
TF_DIR = "terraform"

SYSTEM_PROMPT = (
    "You are a DevSecOps engineer reviewing Terraform for Azure. The code targets "
    "Terraform 1.9+ and the hashicorp/azurerm provider 4.x. Given a failed Checkov "
    "check and the exact Terraform block it flagged, suggest the smallest correct fix. "
    "Keep the resource type and name exactly as given. Show only the arguments or "
    "nested blocks to add or change, inside the real resource header, not the whole "
    "resource. Use only arguments that exist in azurerm 4.x. Never invent placeholder "
    "names. If the fix needs a separate resource, say so and give a complete azurerm "
    "4.x resource that references the flagged resource by its real address."
)


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"Missing required environment variable: {name}")
    return value


def load_findings(path: str) -> list[dict]:
    """Return failed checks from Checkov JSON output, one per check ID."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        print(f"Could not read {path}: {exc}")
        return []

    # Checkov writes one report object for a single framework, or a list for several.
    reports = data if isinstance(data, list) else [data]
    seen: set[str] = set()
    findings: list[dict] = []
    for report in reports:
        for check in report.get("results", {}).get("failed_checks", []):
            check_id = check.get("check_id")
            if check_id and check_id not in seen:
                seen.add(check_id)
                findings.append(check)
    return findings


def flagged_code(check: dict) -> tuple[str, str]:
    """Return (path, code) for the flagged block, read from the checked-out repo.

    Checkov's code_block can be empty (for example with compact output), so the exact
    lines are read from the file using file_line_range. Falls back to code_block.
    """
    start, end = (check.get("file_line_range") or [0, 0])[:2]
    candidates = [
        (check.get("repo_file_path") or "").lstrip("/"),
        os.path.join(TF_DIR, (check.get("file_path") or "").lstrip("/")),
    ]
    for path in candidates:
        if path and start and end and os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                lines = f.readlines()
            return path, "".join(lines[start - 1:end])
    return check.get("file_path", "unknown"), "".join(line for _, line in check.get("code_block") or [])


def build_prompt(check: dict) -> str:
    path, code = flagged_code(check)
    start, end = (check.get("file_line_range") or [0, 0])[:2]
    return (
        f"Checkov check {check.get('check_id')} ({check.get('check_name')}) failed.\n"
        f"Resource address: {check.get('resource')}\n"
        f"File: {path} (lines {start}-{end})\n"
        f"Guideline: {check.get('guideline') or 'none provided'}\n\n"
        f"Flagged Terraform, exactly as it appears in the repo:\n```hcl\n{code.rstrip()}\n```\n\n"
        "Respond in exactly this format:\n"
        "**Issue:** <one sentence>\n"
        "**Fix:**\n```hcl\n<only the changed or added lines, inside the real resource header>\n```\n"
        "**Why it matters:** <one sentence>"
    )


def get_suggestion(client: AzureOpenAI, deployment: str, check: dict) -> str | None:
    try:
        response = client.chat.completions.create(
            model=deployment,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": build_prompt(check)},
            ],
            max_tokens=600,
            temperature=0,
        )
        return response.choices[0].message.content
    except Exception as exc:  # one failed call should not sink the whole comment
        print(f"Azure OpenAI call failed for {check.get('check_id')}: {exc}")
        return None


def upsert_comment(repo: str, pr_number: str, token: str, body: str) -> None:
    """Update the existing remediation comment if there is one, otherwise create it."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    comments_url = f"{GITHUB_API}/repos/{repo}/issues/{pr_number}/comments"

    resp = requests.get(comments_url, headers=headers, params={"per_page": 100}, timeout=15)
    resp.raise_for_status()
    existing = next((c for c in resp.json() if COMMENT_MARKER in (c.get("body") or "")), None)

    if existing:
        resp = requests.patch(
            f"{GITHUB_API}/repos/{repo}/issues/comments/{existing['id']}",
            headers=headers,
            json={"body": body},
            timeout=15,
        )
    else:
        resp = requests.post(comments_url, headers=headers, json={"body": body}, timeout=15)

    if resp.status_code not in (200, 201):
        sys.exit(f"Failed to post PR comment: {resp.status_code} {resp.text}")
    print("PR comment posted.")


def main() -> None:
    endpoint = require_env("AZURE_OPENAI_ENDPOINT")
    deployment = require_env("AZURE_OPENAI_DEPLOYMENT")
    gh_token = require_env("GITHUB_TOKEN")
    repo = require_env("GITHUB_REPOSITORY")
    pr_number = require_env("PR_NUMBER")

    findings = load_findings(RESULTS_FILE)
    if not findings:
        print("No failed Checkov checks found; nothing to post.")
        return

    token_provider = get_bearer_token_provider(
        AzureCliCredential(), "https://cognitiveservices.azure.com/.default"
    )
    client = AzureOpenAI(
        azure_endpoint=endpoint,
        azure_ad_token_provider=token_provider,
        api_version=API_VERSION,
        timeout=30,
        max_retries=3,
    )

    shown = findings[:MAX_FINDINGS]
    sections = [
        COMMENT_MARKER,
        "## 🛡️ AI security remediation",
        "",
        f"The Checkov gate blocked this PR with **{len(findings)}** unique failed check(s). "
        "The fixes below are AI-generated suggestions: review them before applying.",
        "",
    ]

    for i, check in enumerate(shown, start=1):
        check_id = check.get("check_id", "UNKNOWN")
        start, end = (check.get("file_line_range") or [0, 0])[:2]
        print(f"[{i}/{len(shown)}] Requesting fix for {check_id} on {check.get('resource')}")

        suggestion = get_suggestion(client, deployment, check)
        path, _ = flagged_code(check)
        sections += [
            "---",
            f"### {i}. `{check_id}`: {check.get('check_name', '')}",
            f"**Resource:** `{check.get('resource')}` in `{path}` (lines {start}-{end})",
            "",
            suggestion or "_The AI call failed for this finding. See the job log._",
            "",
        ]
        if i < len(shown):
            time.sleep(1)  # basic rate limiting between calls

    if len(findings) > MAX_FINDINGS:
        sections.append(
            f"_{len(findings) - MAX_FINDINGS} more finding(s) not shown. Fix these first, then push again._"
        )

    upsert_comment(repo, pr_number, gh_token, "\n".join(sections))


if __name__ == "__main__":
    main()
