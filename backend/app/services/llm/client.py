import json
from collections.abc import AsyncIterator
from typing import Any

import httpx

from app.core.config import settings
from app.services.context_compression import prompt_cache_model_kwargs


class LLMClient:
    # DeepSeek 的 json_object 响应格式要求提示词里必须出现 "json" 字样，否则返回 400。
    # 缺失时补一句兜底说明，避免原来的「异常被吞掉 -> 静默返回 {}」这类无声降级。
    _JSON_HINT = "\n\nReturn the result as a single strict JSON object."

    def __init__(self) -> None:
        self.base_url = settings.llm_base_url.rstrip("/")
        self.api_key = settings.llm_api_key
        self.model = settings.llm_model

    @classmethod
    def _ensure_json_hint(cls, prompt: str) -> str:
        return prompt if "json" in prompt.lower() else prompt + cls._JSON_HINT

    async def chat_json(self, system_prompt: str, user_payload: dict[str, Any]) -> dict[str, Any]:
        if not self.api_key:
            return {}

        messages = [
            {"role": "system", "content": self._ensure_json_hint(system_prompt)},
            {"role": "user", "content": json.dumps(user_payload, ensure_ascii=False)},
        ]
        try:
            return await self._chat_json_once(messages)
        except httpx.HTTPStatusError:
            # 少数 OpenAI 兼容服务不支持 response_format，去掉后重试一次。
            return await self._chat_json_once(messages, with_response_format=False)

    async def _chat_json_once(
        self, messages: list[dict[str, str]], *, with_response_format: bool = True
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"model": self.model, "messages": messages}
        if with_response_format:
            payload["response_format"] = {"type": "json_object"}
        payload.update(prompt_cache_model_kwargs())
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.post(
                f"{self.base_url}/chat/completions",
                headers={"Authorization": f"Bearer {self.api_key}"},
                json=payload,
            )
            response.raise_for_status()
            content = response.json()["choices"][0]["message"]["content"]
            return json.loads(content)

    async def chat_text(self, system_prompt: str, user_message: str) -> str:
        if not self.api_key:
            return ""

        payload: dict[str, Any] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_message},
            ],
        }
        payload.update(prompt_cache_model_kwargs())
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.post(
                f"{self.base_url}/chat/completions",
                headers={"Authorization": f"Bearer {self.api_key}"},
                json=payload,
            )
            try:
                response.raise_for_status()
            except httpx.HTTPStatusError:
                return ""
            return str(response.json()["choices"][0]["message"].get("content") or "")

    async def chat_text_stream(self, system_prompt: str, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        if not self.api_key:
            return

        payload_messages = [{"role": "system", "content": system_prompt}, *messages]
        payload: dict[str, Any] = {"model": self.model, "messages": payload_messages, "stream": True}
        payload.update(prompt_cache_model_kwargs())
        async with httpx.AsyncClient(timeout=60) as client:
            async with client.stream(
                "POST",
                f"{self.base_url}/chat/completions",
                headers={"Authorization": f"Bearer {self.api_key}"},
                json=payload,
            ) as response:
                try:
                    response.raise_for_status()
                except httpx.HTTPStatusError:
                    return
                async for line in response.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data = line.removeprefix("data: ").strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    delta = chunk.get("choices", [{}])[0].get("delta", {})
                    content = delta.get("content")
                    if content:
                        yield str(content)
