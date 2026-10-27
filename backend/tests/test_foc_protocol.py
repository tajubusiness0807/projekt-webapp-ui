"""FOC-USART-Codec: Rahmenaufbau, Prüfsumme, Resynchronisation, Mischer-Umrechnung."""

from __future__ import annotations

import struct

import pytest

from app.controllers.foc_protocol import (
    FeedbackParser,
    FocFeedback,
    decode_command,
    encode_command,
    encode_feedback,
    wheels_to_steer_speed,
)


def test_command_frame_matches_reference_layout() -> None:
    frame = encode_command(steer=0, speed=300)
    assert len(frame) == 8
    start, steer, speed, checksum = struct.unpack("<HhhH", frame)
    assert start == 0xABCD
    assert (steer, speed) == (0, 300)
    # Prüfsumme wie in hoverserial.ino: start ^ steer ^ speed
    assert checksum == (0xABCD ^ 0 ^ 300) & 0xFFFF
    assert frame[:2] == b"\xcd\xab"  # Little Endian


def test_negative_values_use_twos_complement_in_checksum() -> None:
    frame = encode_command(steer=-120, speed=-500)
    assert decode_command(frame) == (-120, -500)
    _, _, _, checksum = struct.unpack("<HhhH", frame)
    assert checksum == (0xABCD ^ (-120 & 0xFFFF) ^ (-500 & 0xFFFF)) & 0xFFFF


@pytest.mark.parametrize("steer,speed", [(1001, 0), (0, -1001), (5000, 5000)])
def test_out_of_range_commands_are_rejected(steer: int, speed: int) -> None:
    with pytest.raises(ValueError):
        encode_command(steer, speed)


def test_corrupted_command_frame_detected() -> None:
    frame = bytearray(encode_command(10, 20))
    frame[4] ^= 0x01
    with pytest.raises(ValueError):
        decode_command(bytes(frame))


def _fb(**kw: int) -> FocFeedback:
    base = dict(cmd1=0, cmd2=100, speed_right_rpm=-150, speed_left_rpm=152, battery_voltage_centi=3870, board_temp_deci=312, cmd_led=0)
    base.update(kw)
    return FocFeedback(**base)  # type: ignore[arg-type]


def test_feedback_roundtrip_and_units() -> None:
    parser = FeedbackParser()
    frames = parser.feed(encode_feedback(_fb()))
    assert len(frames) == 1
    fb = frames[0]
    assert fb.speed_left_rpm == 152 and fb.speed_right_rpm == -150
    assert fb.battery_voltage == pytest.approx(38.70)
    assert fb.board_temp_c == pytest.approx(31.2)
    assert parser.frame_size == 18


def test_feedback_parser_resynchronises_after_garbage_and_bad_checksum() -> None:
    parser = FeedbackParser()
    good = encode_feedback(_fb())
    bad = bytearray(encode_feedback(_fb(cmd2=7)))
    bad[-1] ^= 0xFF  # Prüfsumme zerstört
    stream = b"\x00\x11\xcd" + bytes(bad) + good[:5]
    assert parser.feed(stream) == []
    frames = parser.feed(good[5:])
    assert len(frames) == 1
    assert frames[0].cmd2 == 100
    assert parser.frames_bad >= 1
    assert parser.frames_ok == 1


def test_feedback_split_across_reads() -> None:
    parser = FeedbackParser()
    data = encode_feedback(_fb()) + encode_feedback(_fb(speed_left_rpm=10))
    out = []
    for i in range(0, len(data), 3):
        out.extend(parser.feed(data[i : i + 3]))
    assert [f.speed_left_rpm for f in out] == [152, 10]


def test_feedback_with_odometry_has_22_bytes() -> None:
    parser = FeedbackParser(with_odometry=True)
    frame = encode_feedback(_fb(wheel_right_count=5, wheel_left_count=-3), with_odometry=True)
    assert len(frame) == 22
    fb = parser.feed(frame)[0]
    assert (fb.wheel_right_count, fb.wheel_left_count) == (5, -3)


def test_odometry_mismatch_is_not_silently_accepted() -> None:
    parser = FeedbackParser(with_odometry=False)
    frames = parser.feed(encode_feedback(_fb(), with_odometry=True) * 2)
    # 22-Byte-Rahmen als 18-Byte-Rahmen gelesen: Prüfsumme passt nicht
    assert frames == []
    assert parser.frames_bad > 0


def test_mixer_inverse_matches_firmware_mixer() -> None:
    # Firmware: R = speed − steer, L = speed + steer (Koeffizienten 1,0)
    steer, speed = wheels_to_steer_speed(1.0, 0.5, speed_coefficient=1.0, steer_coefficient=1.0, max_command=400)
    assert speed + steer == 400  # links
    assert speed - steer == 200  # rechts


def test_mixer_without_steering_coefficient_sends_no_differential() -> None:
    steer, speed = wheels_to_steer_speed(1.0, 0.0, speed_coefficient=1.0, steer_coefficient=0.0, max_command=300)
    assert steer == 0
    assert speed == 150


def test_mixer_respects_max_command_and_input_limit() -> None:
    steer, speed = wheels_to_steer_speed(1.0, 1.0, speed_coefficient=0.5, steer_coefficient=1.0, max_command=1000)
    assert abs(speed) <= 1000 and abs(steer) <= 1000
