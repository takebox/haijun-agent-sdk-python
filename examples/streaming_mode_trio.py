#!/usr/bin/env python3
"""
Example of multi-turn conversation using trio with the Haijun SDK.

This demonstrates how to use the HaijunSDKClient with trio for interactive,
stateful conversations where you can send follow-up messages based on
Haijun's responses.
"""

import trio

from haijun_agent_sdk import (
    AssistantMessage,
    HaijunAgentOptions,
    HaijunSDKClient,
    ResultMessage,
    SystemMessage,
    TextBlock,
    UserMessage,
)


def display_message(msg):
    """Standardized message display function.

    - UserMessage: "User: <content>"
    - AssistantMessage: "Haijun: <content>"
    - SystemMessage: ignored
    - ResultMessage: "Result ended" + cost if available
    """
    if isinstance(msg, UserMessage):
        for block in msg.content:
            if isinstance(block, TextBlock):
                print(f"User: {block.text}")
    elif isinstance(msg, AssistantMessage):
        for block in msg.content:
            if isinstance(block, TextBlock):
                print(f"Haijun: {block.text}")
    elif isinstance(msg, SystemMessage):
        # Ignore system messages
        pass
    elif isinstance(msg, ResultMessage):
        print("Result ended")


async def multi_turn_conversation():
    """Example of a multi-turn conversation using trio."""
    async with HaijunSDKClient(
        options=HaijunAgentOptions(model="haijun-sonnet-5")
    ) as client:
        print("=== Multi-turn Conversation with Trio ===\n")

        # First turn: Simple math question
        print("User: What's 15 + 27?")
        await client.query("What's 15 + 27?")

        async for message in client.receive_response():
            display_message(message)
        print()

        # Second turn: Follow-up calculation
        print("User: Now multiply that result by 2")
        await client.query("Now multiply that result by 2")

        async for message in client.receive_response():
            display_message(message)
        print()

        # Third turn: One more operation
        print("User: Divide that by 7 and round to 2 decimal places")
        await client.query("Divide that by 7 and round to 2 decimal places")

        async for message in client.receive_response():
            display_message(message)

        print("\nConversation complete!")


if __name__ == "__main__":
    trio.run(multi_turn_conversation)
