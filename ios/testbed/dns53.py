#!/usr/bin/env python3
"""A DNS forwarder on 127.0.0.1:53 (run as root) to the testbed's own DNS on 127.0.0.1:28353 — the
fallback when this Mac's resolver does not take /etc/resolver/lumentest's "port 28353" (ci.sh)."""
import asyncio
import sys

UPSTREAM = ("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 28353)


class Forward(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        asyncio.ensure_future(self.ask(data, addr))

    async def ask(self, data, addr):
        loop = asyncio.get_running_loop()
        answer = loop.create_future()

        class Back(asyncio.DatagramProtocol):
            def datagram_received(self, reply, _):
                if not answer.done():
                    answer.set_result(reply)
        transport, _ = await loop.create_datagram_endpoint(Back, remote_addr=UPSTREAM)
        try:
            transport.sendto(data)
            self.transport.sendto(await asyncio.wait_for(answer, 3), addr)
        except Exception:
            pass
        finally:
            transport.close()


async def main():
    await asyncio.get_running_loop().create_datagram_endpoint(Forward, local_addr=("127.0.0.1", 53))
    print("forwarding 127.0.0.1:53 ->", UPSTREAM, flush=True)
    await asyncio.Event().wait()


asyncio.run(main())
