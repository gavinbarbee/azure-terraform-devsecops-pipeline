"""Minimal FastAPI wrapper around the Azure OpenAI deployment Terraform creates.

Keyless: DefaultAzureCredential picks up your `az login` session locally, and the
OpenAI account has API key auth disabled. Your user needs the
"Cognitive Services OpenAI User" role (bootstrap.ps1 grants it).

Run from the app folder:
    uvicorn main:app --reload
"""

import os

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from fastapi import FastAPI
from openai import AzureOpenAI
from pydantic import BaseModel

API_VERSION = "2024-10-21"
DEPLOYMENT = os.environ["AZURE_OPENAI_DEPLOYMENT"]

client = AzureOpenAI(
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
    azure_ad_token_provider=get_bearer_token_provider(
        DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default"
    ),
    api_version=API_VERSION,
)

app = FastAPI(title="DevSecOps Pipeline AI API")


class ChatRequest(BaseModel):
    message: str


class ChatResponse(BaseModel):
    reply: str
    model: str
    tokens_used: int


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/chat", response_model=ChatResponse)
def chat(request: ChatRequest) -> ChatResponse:
    response = client.chat.completions.create(
        model=DEPLOYMENT,
        messages=[
            {"role": "system", "content": "You are a helpful cloud infrastructure assistant."},
            {"role": "user", "content": request.message},
        ],
        max_tokens=500,
    )
    return ChatResponse(
        reply=response.choices[0].message.content,
        model=response.model,
        tokens_used=response.usage.total_tokens,
    )
