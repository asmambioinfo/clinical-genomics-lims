from .api import send_llm_request
def start_application():
    print("starting application...")
    response = send_llm_request("Hello, LLM!")
    print(f"response: {response}")
    return response

if __name__ == "__main__":
    start_application()