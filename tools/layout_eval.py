"""Rewrites eval.tsv for another layout. On another English layout Korean rows are typed on the
same keys, so their keys become that layout's letters; English and Japanese rows are the same
letters on any layout. Run eval3.py on the output with ARASO_LAYOUT set. For 3-set final and 390
(sebeolsikFinal, sebeolsik390) Korean rows are typed again from their reading; run it with
ARASO_KOREAN_LAYOUT set to the same (docs/keyboard-layouts.md).

usage: python3 layout_eval.py colemak|colemakDH|sebeolsikFinal|sebeolsik390 < eval.tsv > eval-colemak.tsv
"""
import sys

QWERTY = ["qwertyuiop", "asdfghjkl;", "zxcvbnm"]
LAYOUTS = {
    "colemak": ["qwfpgjluy;", "arstdhneio", "zxcvbkm"],
    "colemakDH": ["qwfpbjluy;", "arstgmneio", "zxcdvkh"],
}


def shift(c):
    return ":" if c == ";" else c.upper()


def table(rows):
    t = {}
    for q, l in zip(QWERTY, rows):
        for a, b in zip(q, l):
            t[a] = b
            t[shift(a)] = shift(b)
    return t


# 세벌식 최종, by jamo index (Sebeolsik.swift has the same table by key).
CHO = ["k", "kk", "h", "u", "uu", "y", "i", ";", ";;", "n", "nn", "j", "l", "ll", "o", "0", "'", "p", "m"]
JUNG = ["f", "r", "6", "G", "t", "c", "e", "7", "v", "/f", "/r", "/d", "4", "b", "9t", "9c", "9d", "5", "g", "8", "d"]
JONG = ["", "x", "!", "V", "s", "E", "S", "A", "w", "@", "F", "D", "T", "%", "$", "R", "z", "3", "X", "q", "2",
        "a", "#", "Z", "C", "W", "Q", "1"]


# 세벌식 390: ㅒ on ⇧R, and fewer finals of their own (ㄵ is ㄴ then ㅈ).
JUNG_390 = [j.replace("G", "R") for j in JUNG]
JONG_390 = ["", "x", "F", "xq", "s", "s!", "S", "A", "w", "D", "C", "w3", "wq", "wW", "wQ", "V", "z", "3", "X", "q",
            "2", "a", "!", "Z", "E", "W", "Q", "1"]


def sebeolsik(hangul, jung=JUNG, jong=JONG):
    """3-set keys for a Hangul string, or None for anything but complete syllables."""
    keys = []
    for ch in hangul:
        i = ord(ch) - 0xAC00
        if not 0 <= i < 11172:
            return None
        keys.append(CHO[i // 588] + jung[i % 588 // 28] + jong[i % 28])
    return "".join(keys)


def main():
    if sys.argv[1] in ("sebeolsikFinal", "sebeolsik390"):
        t, three = {}, sys.argv[1]
    else:
        t, three = table(LAYOUTS[sys.argv[1]]), False
    for line in sys.stdin:
        keys, prev, label, reading = line.rstrip("\n").split("\t")
        if label == "korean":
            if three:
                keys = sebeolsik(reading) if three == "sebeolsikFinal" else sebeolsik(reading, JUNG_390, JONG_390)
                if keys is None:
                    continue
            else:
                keys = "".join(t.get(c, c) for c in keys)
        print("\t".join([keys, prev, label, reading]))


if __name__ == "__main__":
    main()
