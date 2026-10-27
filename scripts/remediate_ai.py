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

SYSTEM_PROMPT = (
    "You are a DevSecOps engineer who specializes in Terraform on Azure. "
    "Given a failed Checkov check and the Terraform block it flagged, return a "
    "corrected block and a short explanation. Be concise and practical. Change "
    "only what the check requires."
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


def flagged_code(check: dict) -> str:
    """Checkov stores the flagged block as [line_number, text] pairs."""
    return "".join(line for _, line in check.get("code_block") or [])


def build_prompt(check: dict) -> str:
    return (
        f"Checkov check {check.get('check_id')} ({check.get('check_name')}) failed.\n"
        f"Resource: {check.get('resource')}\n"
        f"File: {check.get('file_path')}\n"
        f"Guideline: {check.get('guideline') or 'none provided'}\n\n"
        f"Flagged Terraform:\n```hcl\n{flagged_code(check)}\n```\n\n"
        "Respond in exactly this format:\n"
        "**Issue:** <one sentence>\n"
        "**Fix:**\n```hcl\n<corrected block>\n```\n"
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
            temperature=0.1,
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
        sections += [
            "---",
            f"### {i}. `{check_id}`: {check.get('check_name', '')}",
            f"**Resource:** `{check.get('resource')}` in `{check.get('file_path')}` (lines {start}-{end})",
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
