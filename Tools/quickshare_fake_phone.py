#!/usr/bin/env python3
"""A pretend Android phone that sends files with Quick Share. Developer tool.

It is used to test Phone Mirror's "Receive with Quick Share" without a real phone. It is
written separately from the app on purpose: it uses Google's own message definitions
(compiled with protoc) and the Python "cryptography" library, while the app uses its own
small encoder and Apple's CryptoKit. If the two can talk to each other, the app's messages
and encryption follow the real format, not just the app's own idea of it.

One-time setup (everything goes into the build/ folder, nothing is installed system-wide):

    mkdir -p build/reference && cd build/reference
    python3 -m venv venv && ./venv/bin/pip install grpcio-tools cryptography
    # put Google's .proto files (from the NearDrop project's NearbyShare/ProtobufSource) in protos/
    mkdir -p pb && ./venv/bin/python -m grpc_tools.protoc -I protos --python_out=pb protos/*.proto

Use:

    build/reference/venv/bin/python Tools/quickshare_fake_phone.py --pb build/reference/pb \
        --port 12345 photo.jpg notes.pdf

`swift test` runs this by itself when the setup above has been done (see QuickShareTests).

Exit codes: 0 sent and accepted, 3 declined by the receiver, 1 anything else.
"""

import argparse
import hashlib
import hmac
import os
import socket
import struct
import sys

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--pb", required=True, help="folder with the compiled *_pb2.py files")
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--name", default="Pretend Pixel")
parser.add_argument("--text", help="send this text instead of files")
parser.add_argument("--link", help="send this link instead of files")
parser.add_argument("--send-as", action="append", default=[],
                    help="announce the next file under this name instead of its own (repeatable)")
parser.add_argument("--chunk", type=int, default=512 * 1024, help="bytes per file piece")
parser.add_argument("--last-piece-carries-data", action="store_true",
                    help="put the 'last piece' mark on the final piece of data instead of on an empty one")
parser.add_argument("--tamper", action="store_true", help="flip one bit in the first encrypted message")
parser.add_argument("--too-much", action="store_true", help="send more bytes than announced")
parser.add_argument("--quit-after-offer", action="store_true", help="close the connection right after the offer")
parser.add_argument("files", nargs="*")
args = parser.parse_args()

sys.path.insert(0, os.path.abspath(args.pb))
import device_to_device_messages_pb2 as d2d  # noqa: E402
import offline_wire_formats_pb2 as offline  # noqa: E402
import securegcm_pb2 as securegcm  # noqa: E402
import securemessage_pb2 as securemessage  # noqa: E402
import ukey_pb2 as ukey  # noqa: E402
import wire_format_pb2 as sharing  # noqa: E402
from cryptography.hazmat.primitives import hashes, padding  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes  # noqa: E402
from cryptography.hazmat.primitives.kdf.hkdf import HKDF  # noqa: E402


def hkdf(key, salt, info):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(key)


def java_number(value):
    """A positive number the way Java's BigInteger.toByteArray() writes it."""
    return value.to_bytes(value.bit_length() // 8 + 1, "big")


class Phone:
    def __init__(self):
        self.sock = socket.create_connection((args.host, args.port), timeout=20)
        self.sent = 0
        self.received = 0
        self.tampered = False

    # --- the wire: four bytes of length, then the message ---

    def send_raw(self, data):
        self.sock.sendall(struct.pack(">I", len(data)) + data)

    def read_exactly(self, count):
        data = b""
        while len(data) < count:
            piece = self.sock.recv(count - len(data))
            if not piece:
                raise EOFError("the receiver closed the connection")
            data += piece
        return data

    def read_raw(self):
        (length,) = struct.unpack(">I", self.read_exactly(4))
        return self.read_exactly(length)

    # --- key exchange (UKEY2) ---

    def handshake(self):
        request = offline.OfflineFrame()
        request.version = offline.OfflineFrame.V1
        request.v1.type = offline.V1Frame.CONNECTION_REQUEST
        request.v1.connection_request.endpoint_id = "FAKE"
        request.v1.connection_request.endpoint_name = args.name
        name = args.name.encode()
        request.v1.connection_request.endpoint_info = bytes([1 << 1]) + os.urandom(16) + bytes([len(name)]) + name
        request.v1.connection_request.mediums.append(offline.ConnectionRequestFrame.WIFI_LAN)
        self.send_raw(request.SerializeToString())

        private = ec.generate_private_key(ec.SECP256R1())
        numbers = private.public_key().public_numbers()
        public = securemessage.GenericPublicKey()
        public.type = securemessage.EC_P256
        public.ec_p256_public_key.x = java_number(numbers.x)
        public.ec_p256_public_key.y = java_number(numbers.y)
        finished = ukey.Ukey2ClientFinished()
        finished.public_key = public.SerializeToString()
        finish = ukey.Ukey2Message()
        finish.message_type = ukey.Ukey2Message.CLIENT_FINISH
        finish.message_data = finished.SerializeToString()
        finish_bytes = finish.SerializeToString()

        hello = ukey.Ukey2ClientInit()
        hello.version = 1
        hello.random = os.urandom(32)
        hello.next_protocol = "AES_256_CBC-HMAC_SHA256"
        commitment = hello.cipher_commitments.add()
        commitment.handshake_cipher = ukey.P256_SHA512
        commitment.commitment = hashlib.sha512(finish_bytes).digest()
        init = ukey.Ukey2Message()
        init.message_type = ukey.Ukey2Message.CLIENT_INIT
        init.message_data = hello.SerializeToString()
        init_bytes = init.SerializeToString()
        self.send_raw(init_bytes)

        server_init_bytes = self.read_raw()
        answer = ukey.Ukey2Message()
        answer.ParseFromString(server_init_bytes)
        if answer.message_type != ukey.Ukey2Message.SERVER_INIT:
            raise RuntimeError(f"expected SERVER_INIT, got message type {answer.message_type}")
        server_init = ukey.Ukey2ServerInit()
        server_init.ParseFromString(answer.message_data)
        assert server_init.version == 1 and len(server_init.random) == 32
        assert server_init.handshake_cipher == ukey.P256_SHA512
        server_key = securemessage.GenericPublicKey()
        server_key.ParseFromString(server_init.public_key)
        assert server_key.type == securemessage.EC_P256
        peer = ec.EllipticCurvePublicNumbers(
            int.from_bytes(server_key.ec_p256_public_key.x, "big", signed=True),
            int.from_bytes(server_key.ec_p256_public_key.y, "big", signed=True),
            ec.SECP256R1()).public_key()

        self.send_raw(finish_bytes)

        shared = hashlib.sha256(private.exchange(ec.ECDH(), peer)).digest()
        transcript = init_bytes + server_init_bytes
        auth = hkdf(shared, b"UKEY2 v1 auth", transcript)
        next_secret = hkdf(shared, b"UKEY2 v1 next", transcript)
        d2d_salt = hashlib.sha256(b"D2D").digest()
        client = hkdf(next_secret, d2d_salt, b"client")
        server = hkdf(next_secret, d2d_salt, b"server")
        message_salt = hashlib.sha256(b"SecureMessage").digest()
        self.encrypt_key = hkdf(client, message_salt, b"ENC:2")
        self.send_hmac_key = hkdf(client, message_salt, b"SIG:1")
        self.decrypt_key = hkdf(server, message_salt, b"ENC:2")
        self.receive_hmac_key = hkdf(server, message_salt, b"SIG:1")

        total, multiplier = 0, 1
        for byte in auth:
            signed = byte - 256 if byte > 127 else byte
            total = int_remainder(total + signed * multiplier, 9973)
            multiplier = (multiplier * 31) % 9973
        self.code = "%04d" % abs(total)

        response = offline.OfflineFrame()
        response.version = offline.OfflineFrame.V1
        response.v1.type = offline.V1Frame.CONNECTION_RESPONSE
        response.v1.connection_response.response = offline.ConnectionResponseFrame.ACCEPT
        response.v1.connection_response.status = 0
        response.v1.connection_response.os_info.type = offline.OsInfo.ANDROID
        self.send_raw(response.SerializeToString())

        theirs = offline.OfflineFrame()
        theirs.ParseFromString(self.read_raw())
        if theirs.v1.type != offline.V1Frame.CONNECTION_RESPONSE:
            raise RuntimeError(f"expected CONNECTION_RESPONSE, got frame type {theirs.v1.type}")
        if theirs.v1.connection_response.response != offline.ConnectionResponseFrame.ACCEPT:
            raise RuntimeError("the receiver refused the connection")
        assert theirs.v1.connection_response.os_info.type == offline.OsInfo.APPLE

    # --- the encrypted layer ---

    def send_frame(self, frame):
        self.sent += 1
        inner = d2d.DeviceToDeviceMessage()
        inner.sequence_number = self.sent
        inner.message = frame.SerializeToString()
        padder = padding.PKCS7(128).padder()
        padded = padder.update(inner.SerializeToString()) + padder.finalize()
        iv = os.urandom(16)
        encryptor = Cipher(algorithms.AES(self.encrypt_key), modes.CBC(iv)).encryptor()
        body = encryptor.update(padded) + encryptor.finalize()
        metadata = securegcm.GcmMetadata()
        metadata.type = securegcm.DEVICE_TO_DEVICE_MESSAGE
        metadata.version = 1
        both = securemessage.HeaderAndBody()
        both.header.signature_scheme = securemessage.HMAC_SHA256
        both.header.encryption_scheme = securemessage.AES_256_CBC
        both.header.iv = iv
        both.header.public_metadata = metadata.SerializeToString()
        both.body = body
        message = securemessage.SecureMessage()
        message.header_and_body = both.SerializeToString()
        message.signature = hmac.new(self.send_hmac_key, message.header_and_body, hashlib.sha256).digest()
        if args.tamper and not self.tampered:
            # Change the message after it was signed, the way someone in the middle would.
            self.tampered = True
            changed = bytearray(message.header_and_body)
            changed[-1] ^= 1
            message.header_and_body = bytes(changed)
        self.send_raw(message.SerializeToString())

    def read_frame(self):
        message = securemessage.SecureMessage()
        message.ParseFromString(self.read_raw())
        expected = hmac.new(self.receive_hmac_key, message.header_and_body, hashlib.sha256).digest()
        if not hmac.compare_digest(expected, message.signature):
            raise RuntimeError("the receiver's message has a wrong signature")
        both = securemessage.HeaderAndBody()
        both.ParseFromString(message.header_and_body)
        assert both.header.signature_scheme == securemessage.HMAC_SHA256
        assert both.header.encryption_scheme == securemessage.AES_256_CBC
        metadata = securegcm.GcmMetadata()
        metadata.ParseFromString(both.header.public_metadata)
        assert metadata.type == securegcm.DEVICE_TO_DEVICE_MESSAGE and metadata.version == 1
        decryptor = Cipher(algorithms.AES(self.decrypt_key), modes.CBC(both.header.iv)).decryptor()
        padded = decryptor.update(both.body) + decryptor.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        inner = d2d.DeviceToDeviceMessage()
        inner.ParseFromString(unpadder.update(padded) + unpadder.finalize())
        self.received += 1
        if inner.sequence_number != self.received:
            raise RuntimeError(f"expected message number {self.received}, got {inner.sequence_number}")
        frame = offline.OfflineFrame()
        frame.ParseFromString(inner.message)
        return frame

    # --- payloads ---

    def send_piece(self, payload_id, kind, total, offset, body, last):
        frame = offline.OfflineFrame()
        frame.version = offline.OfflineFrame.V1
        frame.v1.type = offline.V1Frame.PAYLOAD_TRANSFER
        transfer = frame.v1.payload_transfer
        transfer.packet_type = offline.PayloadTransferFrame.DATA
        transfer.payload_header.id = payload_id
        transfer.payload_header.type = kind
        transfer.payload_header.total_size = total
        transfer.payload_header.is_sensitive = False
        transfer.payload_chunk.offset = offset
        transfer.payload_chunk.flags = 1 if last else 0
        if body:
            transfer.payload_chunk.body = body
        self.send_frame(frame)

    def send_bytes(self, data, payload_id=None):
        payload_id = payload_id if payload_id is not None else new_id()
        kind = offline.PayloadTransferFrame.PayloadHeader.BYTES
        self.send_piece(payload_id, kind, len(data), 0, data, False)
        self.send_piece(payload_id, kind, len(data), len(data), b"", True)

    def send_sharing(self, frame):
        self.send_bytes(frame.SerializeToString())

    def read_sharing(self, wanted):
        """Reads until a sharing frame of the wanted type arrives. Answers keep-alives."""
        buffers = {}
        while True:
            frame = self.read_frame()
            if frame.v1.type == offline.V1Frame.KEEP_ALIVE:
                if not frame.v1.keep_alive.ack:
                    reply = offline.OfflineFrame()
                    reply.version = offline.OfflineFrame.V1
                    reply.v1.type = offline.V1Frame.KEEP_ALIVE
                    reply.v1.keep_alive.ack = True
                    self.send_frame(reply)
                continue
            if frame.v1.type == offline.V1Frame.DISCONNECTION:
                raise Goodbye("the receiver said goodbye")
            if frame.v1.type != offline.V1Frame.PAYLOAD_TRANSFER:
                continue
            transfer = frame.v1.payload_transfer
            assert transfer.payload_header.type == offline.PayloadTransferFrame.PayloadHeader.BYTES
            buffer = buffers.setdefault(transfer.payload_header.id, bytearray())
            assert transfer.payload_chunk.offset == len(buffer)
            buffer += transfer.payload_chunk.body
            if transfer.payload_chunk.flags & 1:
                assert len(buffer) == transfer.payload_header.total_size
                inner = sharing.Frame()
                inner.ParseFromString(bytes(buffers.pop(transfer.payload_header.id)))
                assert inner.version == sharing.Frame.V1
                if inner.v1.type == wanted:
                    return inner


class Goodbye(Exception):
    """The receiver sent its "disconnection" message."""


def int_remainder(value, modulus):
    """Remainder with the sign of the left side, like Java and Swift (Python's % differs)."""
    return value - modulus * int(value / modulus)


def new_id():
    return int.from_bytes(os.urandom(8), "big", signed=True)


def main():
    phone = Phone()
    phone.handshake()
    print(f"CODE {phone.code}", flush=True)

    # Both sides send the two "paired key" messages; the order between them doesn't matter.
    hello = sharing.Frame()
    hello.version = sharing.Frame.V1
    hello.v1.type = sharing.V1Frame.PAIRED_KEY_ENCRYPTION
    hello.v1.paired_key_encryption.secret_id_hash = os.urandom(6)
    hello.v1.paired_key_encryption.signed_data = os.urandom(72)
    phone.send_sharing(hello)
    theirs = phone.read_sharing(sharing.V1Frame.PAIRED_KEY_ENCRYPTION)
    assert len(theirs.v1.paired_key_encryption.signed_data) == 72
    assert len(theirs.v1.paired_key_encryption.secret_id_hash) == 6

    result = sharing.Frame()
    result.version = sharing.Frame.V1
    result.v1.type = sharing.V1Frame.PAIRED_KEY_RESULT
    result.v1.paired_key_result.status = sharing.PairedKeyResultFrame.UNABLE
    phone.send_sharing(result)
    theirs = phone.read_sharing(sharing.V1Frame.PAIRED_KEY_RESULT)
    assert theirs.v1.paired_key_result.status == sharing.PairedKeyResultFrame.UNABLE

    offer = sharing.Frame()
    offer.version = sharing.Frame.V1
    offer.v1.type = sharing.V1Frame.INTRODUCTION
    files = []
    text_id = None
    text = args.text if args.text is not None else args.link
    if text is not None:
        meta = offer.v1.introduction.text_metadata.add()
        meta.type = sharing.TextMetadata.URL if args.link is not None else sharing.TextMetadata.TEXT
        meta.text_title = text[:32]
        meta.size = len(text.encode())
        meta.payload_id = text_id = new_id()
        meta.id = new_id()
    else:
        names = list(args.send_as)
        for path in args.files:
            meta = offer.v1.introduction.file_metadata.add()
            meta.name = names.pop(0) if names else os.path.basename(path)
            meta.size = os.path.getsize(path)
            meta.mime_type = "application/octet-stream"
            meta.type = sharing.FileMetadata.UNKNOWN
            meta.payload_id = new_id()
            meta.id = new_id()
            files.append((path, meta.payload_id, meta.size))
    phone.send_sharing(offer)
    if args.quit_after_offer:
        phone.sock.close()
        print("QUIT", flush=True)
        return 1

    answer = phone.read_sharing(sharing.V1Frame.RESPONSE)
    status = answer.v1.connection_response.status
    if status != sharing.ConnectionResponseFrame.ACCEPT:
        print(f"ANSWER {sharing.ConnectionResponseFrame.Status.Name(status)}", flush=True)
        return 3
    print("ANSWER ACCEPT", flush=True)

    if text is not None:
        phone.send_bytes(text.encode(), text_id)
    kind = offline.PayloadTransferFrame.PayloadHeader.FILE
    for path, payload_id, size in files:
        offset = 0
        with open(path, "rb") as handle:
            while True:
                data = handle.read(args.chunk)
                if not data:
                    break
                is_end = offset + len(data) == size
                phone.send_piece(payload_id, kind, size, offset, data, is_end and args.last_piece_carries_data)
                offset += len(data)
        if args.too_much:
            phone.send_piece(payload_id, kind, size, offset, b"extra", False)
            offset += 5
        if not (args.last_piece_carries_data and size > 0):
            phone.send_piece(payload_id, kind, size, offset, b"", True)

    # The receiver says goodbye once everything has arrived. If something went wrong on its
    # side, it sends "cancel" first.
    try:
        phone.read_sharing(sharing.V1Frame.CANCEL)
        print("CANCELLED", flush=True)
        return 1
    except Goodbye:
        print("DONE", flush=True)
        return 0
    except EOFError:
        print("CLOSED", flush=True)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # a test tool: say what went wrong in one line
        print(f"ERROR {type(error).__name__}: {error}", flush=True)
        sys.exit(1)
