"""
RAW image encrypt/decrypt verification for aes_gcm_core.

Generates a deterministic test image as raw RGB8 bytes, encrypts through the
DUT, decrypts, and verifies pixel-exact match. Optionally saves a side-by-side
comparison PNG via Pillow.
"""

import math
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False


def generate_test_image(width, height):
    pixels = bytearray(width * height * 3)
    for y in range(height):
        for x in range(width):
            idx = (y * width + x) * 3
            pixels[idx]     = (x * 4) & 0xFF
            pixels[idx + 1] = (y * 4) & 0xFF
            pixels[idx + 2] = ((x + y) * 2) & 0xFF
    return bytes(pixels)


def to_blocks(data: bytes):
    nblocks = math.ceil(len(data) / 16) if len(data) > 0 else 0
    blocks = []
    for i in range(nblocks):
        chunk = data[i*16:(i+1)*16]
        if len(chunk) < 16:
            chunk = chunk + b'\x00' * (16 - len(chunk))
        blocks.append(int.from_bytes(chunk, "big"))
    return blocks


def blocks_to_bytes(blocks, total_bytes):
    result = b''
    for blk in blocks:
        result += blk.to_bytes(16, "big")
    return result[:total_bytes]


async def reset_dut(dut):
    dut.i_rst_n.value = 0
    dut.i_start_valid.value = 0
    dut.i_encrypt.value = 1
    dut.i_key_len.value = 0
    dut.i_key.value = 0
    dut.i_nonce.value = 0
    dut.i_aad_bytes.value = 0
    dut.i_data_bytes.value = 0
    dut.i_tag.value = 0
    dut.i_s_valid.value = 0
    dut.i_s_data.value = 0
    dut.i_m_ready.value = 1
    dut.i_done_ready.value = 1
    for _ in range(10):
        await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)


async def start_packet(dut, encrypt, key, nonce, aad_bytes, data_bytes, tag=0):
    dut.i_encrypt.value = 1 if encrypt else 0
    dut.i_key_len.value = {16: 0, 24: 1, 32: 2}[len(key)]
    dut.i_key.value = int.from_bytes(key, "big") << (256 - len(key) * 8)
    dut.i_nonce.value = int.from_bytes(nonce, "big")
    dut.i_aad_bytes.value = aad_bytes
    dut.i_data_bytes.value = data_bytes
    dut.i_tag.value = tag
    dut.i_start_valid.value = 1
    while True:
        await RisingEdge(dut.i_clk)
        if int(dut.o_start_ready.value) == 1:
            break
    dut.i_start_valid.value = 0


async def send_blocks(dut, blocks):
    for block in blocks:
        dut.i_s_data.value = block
        dut.i_s_valid.value = 1
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.o_s_ready.value) == 1:
                break
    dut.i_s_valid.value = 0
    dut.i_s_data.value = 0


async def collect_output(dut, data_bytes, timeout_cycles=200000):
    data_blocks = math.ceil(data_bytes / 16) if data_bytes > 0 else 0
    data = []
    for _ in range(timeout_cycles):
        await RisingEdge(dut.i_clk)
        if int(dut.o_m_valid.value) == 1 and int(dut.i_m_ready.value) == 1:
            data.append(int(dut.o_m_data.value))
        if int(dut.o_done_valid.value) == 1 and int(dut.i_done_ready.value) == 1:
            tag = int(dut.o_tag.value)
            auth_ok = int(dut.o_auth_ok.value)
            error = int(dut.o_error.value)
            return data, tag, auth_ok, error
    raise AssertionError(f"timeout: outputs={len(data)}/{data_blocks}")


async def run_packet(dut, encrypt, key, nonce, aad, payload, tag=0):
    aad_blocks = to_blocks(aad)
    payload_blocks = to_blocks(payload)
    collector = cocotb.start_soon(collect_output(dut, len(payload)))
    await start_packet(dut, encrypt, key, nonce, len(aad), len(payload), tag)
    await send_blocks(dut, aad_blocks + payload_blocks)
    return await collector


def save_comparison_png(original_bytes, decrypted_bytes, width, height, path):
    if not HAS_PIL:
        return
    orig_img = Image.frombytes("RGB", (width, height), original_bytes)
    dec_img = Image.frombytes("RGB", (width, height), decrypted_bytes)
    comp = Image.new("RGB", (width * 3, height))
    # Encrypt the original with known params for the "encrypted" visual
    comp.paste(orig_img, (0, 0))
    comp.paste(dec_img, (width * 2, 0))
    comp.save(path)


@cocotb.test()
async def test_image_64x64_aligned(dut):
    """64x64 RGB8 image: 12288 bytes, exactly 16-byte aligned."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    width, height = 64, 64
    key = bytes(range(16))
    nonce = bytes(range(12))
    aad = b"image-header-v1"  # 15 bytes AAD
    raw_data = generate_test_image(width, height)

    dut._log.info(f"Image size: {len(raw_data)} bytes = "
                  f"{math.ceil(len(raw_data)/16)} blocks")

    # Encrypt
    golden = AESGCM(key).encrypt(nonce, raw_data, aad)
    expected_cipher = golden[:-16]
    expected_tag = int.from_bytes(golden[-16:], "big")

    enc_data, enc_tag, enc_auth_ok, enc_error = await run_packet(
        dut, True, key, nonce, aad, raw_data, 0
    )
    enc_bytes = blocks_to_bytes(enc_data, len(raw_data))
    assert enc_bytes == expected_cipher, "Encrypted image mismatch"
    assert enc_tag == expected_tag
    assert enc_auth_ok == 1

    dut._log.info("Encryption passed, starting decryption...")
    await RisingEdge(dut.i_clk)

    # Decrypt
    dec_data, dec_tag, dec_auth_ok, dec_error = await run_packet(
        dut, False, key, nonce, aad, expected_cipher, expected_tag
    )
    dec_bytes = blocks_to_bytes(dec_data, len(raw_data))
    assert dec_bytes == raw_data, "Decrypted image does not match original!"
    assert dec_auth_ok == 1

    dut._log.info("Image encrypt/decrypt round-trip PASSED")

    save_comparison_png(raw_data, dec_bytes, width, height,
                        "image_64x64_comparison.png")


@cocotb.test()
async def test_image_100x75_unaligned(dut):
    """100x75 RGB8 image: 22500 bytes, not 16-byte aligned."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    width, height = 100, 75
    key = bytes(range(32))
    nonce = bytes(range(12))
    aad = b"img-hdr"  # 7 bytes
    raw_data = generate_test_image(width, height)

    dut._log.info(f"Image size: {len(raw_data)} bytes, "
                  f"last block: {len(raw_data) % 16} bytes")

    golden = AESGCM(key).encrypt(nonce, raw_data, aad)
    expected_cipher = golden[:-16]
    expected_tag = int.from_bytes(golden[-16:], "big")

    # Encrypt
    enc_data, enc_tag, enc_auth_ok, enc_error = await run_packet(
        dut, True, key, nonce, aad, raw_data, 0
    )
    enc_bytes = blocks_to_bytes(enc_data, len(raw_data))
    assert enc_bytes == expected_cipher
    assert enc_tag == expected_tag

    await RisingEdge(dut.i_clk)

    # Decrypt
    dec_data, dec_tag, dec_auth_ok, dec_error = await run_packet(
        dut, False, key, nonce, aad, expected_cipher, expected_tag
    )
    dec_bytes = blocks_to_bytes(dec_data, len(raw_data))
    assert dec_bytes == raw_data, "Unaligned image decrypt failed!"
    assert dec_auth_ok == 1

    dut._log.info("Unaligned image encrypt/decrypt PASSED")

    save_comparison_png(raw_data, dec_bytes, width, height,
                        "image_100x75_comparison.png")
