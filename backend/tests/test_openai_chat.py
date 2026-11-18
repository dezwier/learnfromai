from app.features.platform.openai_chat import (
    is_openai_reasoning_model,
    openai_chat_body,
    set_openai_max_out,
)


def test_gpt5_mini_uses_max_completion_tokens_and_omits_temperature():
    body = openai_chat_body(
        model="gpt-5-mini",
        messages=[{"role": "user", "content": "hi"}],
        max_out=2048,
        temperature=0.0,
        response_format={"type": "json_object"},
    )
    assert body["max_completion_tokens"] == 2048
    assert "max_tokens" not in body
    assert "temperature" not in body
    assert body["response_format"] == {"type": "json_object"}


def test_gpt4o_mini_keeps_classic_params():
    body = openai_chat_body(
        model="gpt-4o-mini",
        messages=[{"role": "user", "content": "hi"}],
        max_out=1024,
        temperature=0.0,
    )
    assert body["max_tokens"] == 1024
    assert body["temperature"] == 0.0
    assert "max_completion_tokens" not in body


def test_set_openai_max_out_updates_correct_key():
    reasoning = {"max_completion_tokens": 100}
    classic = {"max_tokens": 100}
    set_openai_max_out(reasoning, 500)
    set_openai_max_out(classic, 500)
    assert reasoning["max_completion_tokens"] == 500
    assert classic["max_tokens"] == 500


def test_is_openai_reasoning_model():
    assert is_openai_reasoning_model("gpt-5-mini")
    assert is_openai_reasoning_model("o3")
    assert not is_openai_reasoning_model("gpt-4o-mini")
