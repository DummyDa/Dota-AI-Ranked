"""OpenRouter chat analysis and local Piper voice output for the Dota bridge."""
from __future__ import annotations

import json
import logging
import os
import queue
import re
import threading
import time
import uuid
from collections import deque
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen
from urllib.error import HTTPError


SYSTEM_PROMPT = """You are the voice of an autonomous Spirit Breaker support in Dota 2.
For each incoming player message decide whether that player is directly addressing, asking,
or commanding our Spirit Breaker/player. General team information, jokes, arguments between
other players and enemy messages are not directed to us. Return JSON only:
{"addressed": boolean, "reply": string}.
If is_self is true and the message explicitly addresses Bara/Spirit Breaker, treat it as
an intentional local test and answer normally.
If addressed is true, reply naturally in the message language using at most 12 words.
Never insult, argue, mention being an AI, or invent unavailable game facts.
Enemy messages must always have addressed=false and reply=""."""


class VoiceOutput:
    def __init__(self, model_path: Path, device_hint: str | None = None) -> None:
        from piper import PiperVoice, SynthesisConfig
        import sounddevice as sounddevice

        self._sd = sounddevice
        self._syn_config = SynthesisConfig(length_scale=0.9, volume=0.9)
        self._voice = PiperVoice.load(str(model_path), use_cuda=False)
        self.device_index, self.device_name = self._find_device(device_hint)
        device = self._sd.query_devices(self.device_index)
        self.output_sample_rate = int(float(device.get("default_samplerate", 48000)))
        self.monitor_index, self.monitor_name, self.monitor_sample_rate = self._find_monitor()
        logging.info("Piper loaded: %s; output=%s@%sHz; monitor=%s", model_path.name,
                     self.device_name, self.output_sample_rate, self.monitor_name or "disabled")

    def _find_device(self, hint: str | None) -> tuple[int, str]:
        devices = self._sd.query_devices()
        requested = (hint or os.environ.get("DOTA_TTS_OUTPUT_DEVICE") or "Voicemod").lower()
        candidates: list[tuple[int, str]] = []
        for index, device in enumerate(devices):
            name = str(device.get("name", ""))
            if int(device.get("max_output_channels", 0)) > 0:
                candidates.append((index, name))
                if requested in name.lower():
                    return index, name
        available = ", ".join(name for _, name in candidates)
        raise RuntimeError(f"TTS output device containing {requested!r} not found; outputs: {available}")

    def _find_monitor(self) -> tuple[int | None, str | None, int | None]:
        requested = os.environ.get("DOTA_TTS_MONITOR_DEVICE", "").strip().lower()
        devices = self._sd.query_devices()
        if requested:
            candidates = [i for i, item in enumerate(devices)
                          if int(item.get("max_output_channels", 0)) > 0
                          and requested in str(item.get("name", "")).lower()]
            index = candidates[0] if candidates else None
        else:
            default = self._sd.default.device
            try:
                index = int(default[1])
            except (TypeError, IndexError, ValueError):
                index = None
        if index is None or index < 0 or index == self.device_index:
            return None, None, None
        device = self._sd.query_devices(index)
        if int(device.get("max_output_channels", 0)) <= 0:
            return None, None, None
        return index, str(device.get("name", "default output")), int(float(device.get("default_samplerate", 48000)))

    def synthesize(self, text: str) -> tuple[Any, int, float]:
        import numpy as np

        chunks = list(self._voice.synthesize(text, syn_config=self._syn_config))
        if not chunks:
            raise RuntimeError("Piper returned no audio")
        sample_rate = int(chunks[0].sample_rate)
        audio = np.concatenate([chunk.audio_float_array for chunk in chunks]).astype("float32")
        return audio, sample_rate, len(audio) / sample_rate

    @staticmethod
    def _resample(audio: Any, sample_rate: int, target_rate: int) -> Any:
        if sample_rate == target_rate:
            return audio
        import numpy as np

        target_length = max(1, round(len(audio) * target_rate / sample_rate))
        source_x = np.arange(len(audio), dtype=np.float64)
        target_x = np.linspace(0, max(0, len(audio) - 1), target_length)
        return np.interp(target_x, source_x, audio).astype("float32")

    def _play_device(self, audio: Any, sample_rate: int, device_index: int) -> None:
        with self._sd.OutputStream(samplerate=sample_rate, device=device_index,
                                   channels=1, dtype="float32") as stream:
            stream.write(audio.reshape(-1, 1))

    def play(self, audio: Any, sample_rate: int) -> None:
        destinations = [(self.device_index, self.output_sample_rate)]
        if self.monitor_index is not None and self.monitor_sample_rate is not None:
            destinations.append((self.monitor_index, self.monitor_sample_rate))
        errors: list[Exception] = []
        threads = []
        for index, target_rate in destinations:
            prepared = self._resample(audio, sample_rate, target_rate)
            thread = threading.Thread(
                target=lambda data=prepared, rate=target_rate, device=index:
                    self._play_catching(data, rate, device, errors),
                daemon=True,
            )
            threads.append(thread)
            thread.start()
        for thread in threads:
            thread.join()
        if errors:
            raise errors[0]

    def _play_catching(self, audio: Any, sample_rate: int, device_index: int,
                       errors: list[Exception]) -> None:
        try:
            self._play_device(audio, sample_rate, device_index)
        except Exception as exc:
            errors.append(exc)


class ChatResponder:
    def __init__(self, model: str, piper_model: Path, device_hint: str | None = None) -> None:
        self.model = model
        self.api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
        self.input_queue: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=64)
        self.voice_queue: deque[dict[str, Any]] = deque(maxlen=8)
        self.notices: deque[dict[str, Any]] = deque(maxlen=16)
        self.lock = threading.RLock()
        self.history: deque[dict[str, Any]] = deque(maxlen=12)
        self.last_error = ""
        self.last_analysis: dict[str, Any] | None = None
        self.active_voice: dict[str, Any] | None = None
        self.active_analysis: dict[str, Any] | None = None
        self.last_reply_by_source: dict[int, float] = {}
        self.voice: VoiceOutput | None = None
        try:
            self.voice = VoiceOutput(piper_model, device_hint)
        except Exception as exc:
            self.last_error = str(exc)
            logging.exception("TTS initialization failed")
        self.worker = threading.Thread(target=self._run, name="chat-responder", daemon=True)
        self.worker.start()

    @property
    def enabled(self) -> bool:
        return bool(self.api_key and self.voice)

    def submit(self, message: dict[str, Any]) -> bool:
        own_message_allowed = message.get("selfTest") or message.get("selfAddressed")
        if (message.get("isSelf") and not own_message_allowed) or not str(message.get("messageText", "")).strip():
            return False
        try:
            message = dict(message)
            message["_queuedAt"] = time.monotonic()
            self.input_queue.put_nowait(message)
            return True
        except queue.Full:
            self.last_error = "chat analysis queue is full"
            return False

    def _openrouter(self, message: dict[str, Any]) -> dict[str, Any]:
        if not self.api_key:
            raise RuntimeError("OPENROUTER_API_KEY is not configured")
        compact = {
            "sender": message.get("sourceName") or f"player {message.get('sourcePlayerId')}",
            "hero": message.get("sourceHero") or "unknown",
            "is_ally": bool(message.get("isAlly")),
            "is_self": bool(message.get("isSelf")),
            "channel": "all" if int(message.get("channelType") or 0) == 11 else "team",
            "message": str(message.get("messageText", ""))[:500],
            "our_hero": "Spirit Breaker",
            "our_player_name": message.get("localName") or "unknown",
        }
        context = list(self.history)[-5:]
        request_body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": json.dumps({"recent": context, "current": compact}, ensure_ascii=False)},
            ],
            "temperature": 0.2,
            "max_tokens": 80,
            "reasoning": {"enabled": False},
            "response_format": {"type": "json_object"},
        }
        request = Request(
            "https://openrouter.ai/api/v1/chat/completions",
            data=json.dumps(request_body, ensure_ascii=False).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/DummyDa/Dota-AI-Ranked",
                "X-Title": "Dota AI Ranked",
            },
            method="POST",
        )
        with urlopen(request, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8"))
        content = payload["choices"][0]["message"]["content"]
        if isinstance(content, list):
            content = "".join(str(part.get("text", "")) for part in content if isinstance(part, dict))
        if not content:
            raise RuntimeError("OpenRouter returned an empty response")
        raw = str(content).strip()
        match = re.search(r"\{.*\}", raw, flags=re.DOTALL)
        if not match:
            raise RuntimeError("OpenRouter response did not contain JSON")
        result = json.loads(match.group(0))
        addressed = bool(result.get("addressed")) and bool(message.get("isAlly"))
        words = str(result.get("reply", "")).split()
        reply = " ".join(words[:12])[:180] if addressed else ""
        return {"addressed": addressed and bool(reply), "reply": reply, "model": payload.get("model", self.model)}

    def _run(self) -> None:
        while True:
            message = self.input_queue.get()
            with self.lock:
                self.active_analysis = {
                    "started": time.monotonic(),
                    "source": message.get("sourceName") or "player",
                    "slowSent": False,
                }
            try:
                if message.get("selfTest"):
                    result = {
                        "addressed": True,
                        "reply": "Привет! Голосовой канал работает.",
                        "model": "local-audio-test",
                    }
                else:
                    result = self._openrouter(message)
                with self.lock:
                    self.last_analysis = {**result, "source": message.get("sourceName"), "atText": message.get("messageText")}
                    self.history.append({
                        "sender": message.get("sourceName"),
                        "ally": bool(message.get("isAlly")),
                        "text": str(message.get("messageText", ""))[:200],
                    })
                if not result["addressed"] or not self.voice:
                    with self.lock:
                        self.notices.append({"type": "done", "text": "ответ не требуется",
                                             "chat": False, "final": True})
                    continue
                source_id = int(message.get("sourcePlayerId") or -1)
                now = time.monotonic()
                if now - self.last_reply_by_source.get(source_id, -100.0) < 6.0:
                    with self.lock:
                        self.notices.append({"type": "done", "text": "ответ пропущен: cooldown",
                                             "chat": False, "final": True})
                    continue
                started = time.monotonic()
                audio, sample_rate, duration = self.voice.synthesize(result["reply"])
                job = {
                    "id": uuid.uuid4().hex,
                    "text": result["reply"],
                    "audio": audio,
                    "sampleRate": sample_rate,
                    "duration": duration,
                    "synthesisMs": round((time.monotonic() - started) * 1000),
                }
                with self.lock:
                    self.voice_queue.append(job)
                    self.last_reply_by_source[source_id] = now
                logging.info("Voice reply queued for %s: %s", message.get("sourceName"), result["reply"])
            except Exception as exc:
                self.last_error = str(exc)
                if isinstance(exc, HTTPError) and exc.code == 429:
                    error_text = "Qwen: лимит запросов, ответ пропущен"
                elif isinstance(exc, TimeoutError):
                    error_text = "Qwen: таймаут, ответ не получен"
                else:
                    error_text = "Qwen: ошибка анализа, ответ не получен"
                with self.lock:
                    self.notices.append({"type": "error", "text": error_text,
                                         "chat": True, "final": True})
                logging.exception("Chat analysis failed")
            finally:
                with self.lock:
                    self.active_analysis = None
                self.input_queue.task_done()

    def poll_voice(self) -> dict[str, Any]:
        with self.lock:
            notice = None
            if self.active_analysis is not None:
                elapsed = time.monotonic() - float(self.active_analysis["started"])
                if elapsed >= 4.0 and not self.active_analysis["slowSent"]:
                    self.active_analysis["slowSent"] = True
                    notice = {"type": "slow", "text": "Qwen думает дольше 4 секунд...",
                              "chat": True, "final": False}
            if notice is None and self.notices:
                notice = self.notices.popleft()
            if self.active_voice is not None or not self.voice_queue:
                response = {"ready": False}
                if notice is not None:
                    response["notice"] = notice
                return response
            self.active_voice = self.voice_queue.popleft()
            job = self.active_voice
            response = {
                "ready": True,
                "id": job["id"],
                "text": job["text"],
                "duration": round(float(job["duration"]), 3),
                "synthesisMs": job["synthesisMs"],
            }
            if notice is not None:
                response["notice"] = notice
            return response

    def start_voice(self, job_id: str) -> bool:
        with self.lock:
            job = self.active_voice
            if not job or job["id"] != job_id or job.get("started"):
                return False
            job["started"] = True
        threading.Thread(target=self._play, args=(job,), name="tts-playback", daemon=True).start()
        return True

    def _play(self, job: dict[str, Any]) -> None:
        try:
            assert self.voice is not None
            # Give Source 2 time to open the selected recording endpoint after
            # Lua executes +voicerecord. Without this pre-roll the first (or
            # entire short) phrase can be lost on a virtual cable.
            time.sleep(0.4)
            self.voice.play(job["audio"], job["sampleRate"])
        except Exception as exc:
            self.last_error = str(exc)
            logging.exception("Voice playback failed")
        finally:
            with self.lock:
                if self.active_voice is job:
                    self.active_voice = None

    def status(self) -> dict[str, Any]:
        with self.lock:
            return {
                "enabled": self.enabled,
                "keyConfigured": bool(self.api_key),
                "model": self.model,
                "ttsReady": self.voice is not None,
                "ttsDevice": self.voice.device_name if self.voice else None,
                "ttsSampleRate": self.voice.output_sample_rate if self.voice else None,
                "ttsMonitor": self.voice.monitor_name if self.voice else None,
                "pendingMessages": self.input_queue.qsize(),
                "pendingVoices": len(self.voice_queue),
                "voiceActive": self.active_voice is not None,
                "lastAnalysis": self.last_analysis,
                "lastError": self.last_error or None,
            }
