#!/usr/bin/env python3
"""
Example of using the "include_partial_messages" option to stream partial messages
from Haijun Code SDK.

This feature allows you to receive stream events that contain incremental
updates as Haijun generates responses. This is useful for:
- Building real-time UIs that show text as it's being generated
- Monitoring tool use progress
- Getting early results before the full response is complete

Note: Partial message streaming requires the CLI to support it, and the
messages will include StreamEvent messages interspersed with regular messages.
"""

import asyncio

from haijun_agent_sdk import HaijunSDKClient
from haijun_agent_sdk.types import (
    HaijunAgentOptions,
)


async def main():
    # Enable partial message streaming
    options = HaijunAgentOptions(
        include_partial_messages=True,
        model="haijun-sonnet-5",
        max_turns=2,
        env={
            "MAX_THINKING_TOKENS": "8000",
        },
    )

    client = HaijunSDKClient(options)

    try:
        await client.connect()

        # Send a prompt that will generate a streaming response
        # prompt = "Run a bash command to sleep for 5 seconds"
        prompt = "Think of three jokes, then tell one"
        print(f"Prompt: {prompt}\n")
        print("=" * 50)

        await client.query(prompt)

        async for message in client.receive_response():
            print(message)

    finally:
        await client.disconnect()


if __name__ == "__main__":
    print("Partial Message Streaming Example")
    print("=" * 50)
    asyncio.run(main())
