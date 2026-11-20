"""Render the Llama 3.2 chat prompt ourselves, with a fixed date.

The model's built-in chat template (Llama 3.2 Instruct) writes "Today Date: <the machine's
current date>" into the system header. That makes every run depend on the day it ran, and it
contradicts the fixed reference time each item carries. We render the same text with
date_string taken from the item's reference time instead, then tokenize it with special tokens
parsed and no extra BOS. The iOS app renders the identical string (ios/PrivateEdgeCore), so the
Mac and the phone feed the model the same tokens.

    prompt = render_llama32(system, user, ref_date)   # ref_date: datetime or date
"""
from datetime import date, datetime

TEMPLATE_DATE_FORMAT = "%d %b %Y"  # what the template's strftime_now("%d %b %Y") would print


def date_string(ref) -> str:
    d = ref.date() if isinstance(ref, datetime) else ref
    return d.strftime(TEMPLATE_DATE_FORMAT)


def render_llama32(system: str, user: str, ref) -> str:
    """Equals the GGUF's Jinja template with date_string set, no tools, add_generation_prompt."""
    return (
        "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
        "Cutting Knowledge Date: December 2023\n"
        f"Today Date: {date_string(ref)}\n\n"
        f"{system.strip()}<|eot_id|>"
        f"<|start_header_id|>user<|end_header_id|>\n\n{user.strip()}<|eot_id|>"
        "<|start_header_id|>assistant<|end_header_id|>\n\n"
    )


def tokenize_prompt(llm, prompt: str) -> list[int]:
    # The prompt already starts with <|begin_of_text|>, so no BOS is added.
    return llm.tokenize(prompt.encode(), add_bos=False, special=True)
