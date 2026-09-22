"""Managed Open WebUI Pipe for a personal GigaCode subscription.

The Pipe is intentionally a small trusted adapter.  It derives the subject
only from Open WebUI's server-side OIDC user record, receives a 60-second JWT
from the internal broker, and can reach only the subject-specific Agentgateway
route.  Neither prompts nor bearer values are logged.
"""

import hashlib
import re
from pathlib import Path

import httpx


_SUBJECT = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
_CALLER_FILE = Path("/run/secrets/ai-stand-gigacode-broker-openwebui-caller")
_BROKER_URL = "http://gigacode-identity-broker:8080"
_GATEWAY_URL = "http://agentgateway:4000"


class Pipe:
    def pipes(self):
        return [{"id": "codechat", "name": "gigacode"}]

    @staticmethod
    def _subject(user):
        try:
            value = user["oauth"]["oidc"]["sub"]
        except (KeyError, TypeError):
            raise ValueError("GigaCode requires an Authentik OIDC login")
        if not isinstance(value, str) or not _SUBJECT.fullmatch(value):
            raise ValueError("GigaCode subscription identity is unavailable")
        return value.lower()

    @staticmethod
    def _caller_secret():
        try:
            value = _CALLER_FILE.read_text(encoding="utf-8").strip()
        except OSError:
            raise RuntimeError("GigaCode broker is not configured")
        if not value or len(value) > 512:
            raise RuntimeError("GigaCode broker is not configured")
        return value

    @staticmethod
    def _backend_slug(subject):
        # Keep this in lockstep with the reconciler and OpenClaw adapter.  The
        # shortened digest is deterministic, does not expose the Authentik
        # subject in Swarm object names, and fits the Docker name limit after
        # the stack-service prefix has been added.
        digest = hashlib.sha256(subject.lower().encode("ascii")).hexdigest()
        return f"u-{digest[:23]}"

    async def _token(self, subject):
        headers = {
            "Authorization": f"Bearer {self._caller_secret()}",
            "X-AI-Stand-Caller": "openwebui",
        }
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                response = await client.post(f"{_BROKER_URL}/issue", headers=headers, json={"subject": subject})
        except httpx.HTTPError:
            raise RuntimeError("GigaCode broker is unavailable")
        if response.status_code == 401:
            raise RuntimeError("GigaCode broker rejected this request")
        if response.status_code != 200:
            raise RuntimeError("GigaCode subscription is not configured")
        token = response.json().get("access_token")
        if not isinstance(token, str) or len(token) > 8192:
            raise RuntimeError("GigaCode broker returned an invalid token")
        return token

    async def pipe(self, body: dict, __user__: dict):
        subject = self._subject(__user__)
        token = await self._token(subject)
        slug = self._backend_slug(subject)
        url = f"{_GATEWAY_URL}/_internal/gigacode/{slug}/chat/completions"
        request_body = dict(body)
        request_body["model"] = "gigacode/codechat"
        headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

        if request_body.get("stream"):
            async def stream_response():
                try:
                    async with httpx.AsyncClient(timeout=httpx.Timeout(86400, read=86400)) as client:
                        async with client.stream("POST", url, headers=headers, json=request_body) as response:
                            if response.status_code != 200:
                                yield "data: {\"error\":{\"message\":\"GigaCode subscription is not configured\"}}\n\n"
                                return
                            async for chunk in response.aiter_raw():
                                if chunk:
                                    yield chunk
                except httpx.HTTPError:
                    yield "data: {\"error\":{\"message\":\"GigaCode service is unavailable\"}}\n\n"

            return stream_response()

        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(86400, read=86400)) as client:
                response = await client.post(url, headers=headers, json=request_body)
        except httpx.HTTPError:
            raise RuntimeError("GigaCode service is unavailable")
        if response.status_code != 200:
            raise RuntimeError("GigaCode subscription is not configured")
        return response.json()
