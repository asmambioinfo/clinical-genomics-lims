def send_llm_request(text):
    print(f"sending llm req with text: '{text}'")
    return {"status": "request sent", "text": text}
