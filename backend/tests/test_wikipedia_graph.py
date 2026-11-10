import httpx

from app.features.knowledge_graph.wikipedia import WikipediaClient, display_title


def test_wikipedia_client_retries_a_rate_limit_and_sends_a_user_agent():
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        assert request.headers["user-agent"].startswith("AdaptiveMastery/")
        if calls["n"] == 1:
            return httpx.Response(429, headers={"Retry-After": "0"}, json={"error": {"code": "ratelimited"}})
        return httpx.Response(200, json={"batchcomplete": True, "query": {"pages": []}})

    client = WikipediaClient(transport=httpx.MockTransport(handler), sleeper=lambda _delay: None)
    try:
        payload = client.get({"action": "query", "titles": "Category:Dinosaurs"})
    finally:
        client.close()
    assert calls["n"] == 2
    assert payload["batchcomplete"] is True
    assert display_title("Category:Dinosaurs") == "Dinosaurs"
