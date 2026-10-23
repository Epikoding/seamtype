# Keyboard layouts

Araso decides per word between English, Korean and Japanese from the keys typed. Until 0.2.2 it
assumed QWERTY for English and romaji and 2-set (두벌식) for Korean. This is how other layouts fit.

## English layouts (done: Colemak, Colemak-DH)

`settings.json`'s `"latinLayout"`: `"qwerty"` (default), `"colemak"` or `"colemakDH"`; the
English menu of the Languages pane's Layouts card.

**Keys are the layout's letters.** On Colemak `hello` is typed as `hello`, so English, romaji and
everything that reads keys as text (the English model, `RomajiComposer`, URL runs, the
dictionary's English entries) take them as they are.

**Korean looks through to the key.** 2-set Korean sits on QWERTY's letter keys whatever layout the
letters come from, as macOS's own 2-set does. `DubeolsikLayout` turns each key into its QWERTY
seat (`LatinLayout.seat(of:)`) before it asks for a jamo, a Shift double consonant or the
English-only capital check, so 안녕 on Colemak is `serrls` (the d k s s u d keys). That is the
one place Korean reads keys: `HangulComposer`, `MixedWord`, `ParticleSplitter`, `KoreanModel` and
the dictionary's Korean readings all go through it.

**The keys come from the key code.** With a layout other than QWERTY, `InputController` maps the
key code through the layout's rows itself (`LatinLayout.character(keyCode:shift:capsLock:)`), so the
setting decides, not whichever layout macOS hands the input method. A key is part of a word when
the layout types a letter on it or it is one of QWERTY's letter keys (2-set has a jamo there):
Colemak's `;` on the p key is 2-set's ㅔ and keeps the word composing.

**Where the layout comes from.** `LatinLayout.active`, set by `Runtime` from the settings (the
settings window's change reaches it through the usual notification). A test or tool overrides it
for its own task with `LatinLayout.$override.withValue(.colemak) { … }`; `araso-cli` takes
`ARASO_LAYOUT=colemak`.

**Romaji can have its own layout.** `settings.json`'s `"japaneseLayout"` (absent: English's);
the Romaji menu of the Languages pane's Layouts card. Keys stay English's letters, and
`RomajiComposer.compose`, which every Japanese reading goes through, first turns each into
romaji's letter on the same key (`LatinLayout.romajiKeys`), as 2-set looks through to the key. A
key romaji's layout has a letter on is part of a word (`isLetterSeat`): QWERTY's `;` when romaji is
on Colemak. `araso-cli` takes `ARASO_JAPANESE_LAYOUT`. English on Colemak with romaji on QWERTY
scores 99.63% on eval.tsv, above every single layout: the same letters no longer spell English
and romaji both.

**QWERTY is unchanged**: a key and its seat are the same character there.

**Accuracy** (eval.tsv, 5,998 held-out words and phrases, Japanese on; Korean rows rewritten to
each layout's letters with `tools/layout_eval.py`, English and Japanese rows are the same letters):

| layout | accuracy | English → Korean | Korean → English |
|---|---|---|---|
| QWERTY | 99.47% | 5 | 4 |
| Colemak | 99.35% | 9 | 7 |
| Colemak-DH | 99.33% | 9 | 8 |

The difference is which English words land on keys that spell real Hangul: on Colemak `git` is on
the t l f keys (실), `ti` on f l (리), `wes` on w k d (장). The weights were tuned on QWERTY's
collisions; Colemak's are a different set of about the same size. A word that keeps coming out
wrong is fixed the usual way: switched twice, the dictionary keeps it.

**What doesn't carry over.** The dictionary stores keys as typed, so words learned on one layout
don't match on another (their keys differ).

**Typing test.** `scripts/typing-test/colemak.tsv` runs on Colemak through the installed app; its
scripts are the QWERTY keys pressed (`hkuu;` for hello), so the key-code path is covered too.

## Dvorak (not done)

Dvorak puts `'`, `,`, `.` and `;` on the keys of 2-set's ㅂ, ㅈ, ㄷ and ㅋ. On those keys a word
would have to end (English punctuation) and keep composing (Korean jamo) at once. Needs a rule
for trailing punctuation keys: split them off when the word before reads well without them and
the jamo would leave broken Hangul (안녕. not 안녕ㄷ), with its own evaluation, including common
cases like `가.` where the jamo makes a valid syllable (갇). 3-set's `KoreanLayout.continuesWord`
is that rule for digits and symbols decided as they are typed; Dvorak's `.` and `,` end sentences
far more often than 3-set's `!` does, so it would need deciding at the word's end instead.

## 세벌식 최종 and 390 (done)

`settings.json`'s `"koreanLayout"`: `"dubeolsik"` (default), `"sebeolsikFinal"` or `"sebeolsik390"`; the Hangul menu
of the Languages pane's Layouts card. `KoreanLayout` mirrors `LatinLayout` (`active`, `$override`, `current`;
`araso-cli` takes `ARASO_KOREAN_LAYOUT`).

**One way in.** Everything that reads keys as Korean goes through `HangulComposer.compose(keys:)`
and `DubeolsikLayout`'s statics; with 3-set chosen they answer for `Sebeolsik`
(Sebeolsik.swift), which returns the same `HangulComposer.Result`. Its tables are macOS's
(3SetHangul and 390Hangul.keylayout in KoreanIM.app), which `SebeolsikKeylayoutTests` checks
key by key, all 94 with Shift. The table goes by QWERTY seat,
so 3-set on Colemak works as 2-set does. The composer fills initial, medial and final in order
(ㄱㄱ ㄷㄷ ㅂㅂ ㅅㅅ ㅈㅈ double an initial, ㄱㄱ ㅅㅅ a final, vowels combine as on 2-set); there is
no 도깨비불, so a vowel after a final is a stray jamo. 2-set-only rules stay 2-set's: the lingering
Shift (on 3-set a shifted letter is a final, or a digit or symbol: ⇧H is 0, so a capital with no
jamo is English), the 갷/개ㅎ rescoring, and chat jamo, which on 3-set must be one jamo repeated
(ㅋㅋ, ㅎㅎ; its consonants sit on the right hand's letters, so jun is ㅇㄷㅅ).

**Digits and symbols.** They reach the session as printable keys. `KoreanLayout.continuesWord`
lets one go on with the word when its jamo fits: a word starts on an initial (ㅂ ;, ㅌ ', ㅋ 0, not
0 right after a digit), and a vowel or final has to make a syllable the model knows (갔 kf2, 밝
;f@; not 안녕! or 하세요!, whose ㄲ makes nothing or 욖). Inside a URL or path they stay symbols.
Keys of digits only read as a number to the engine: 2026 and 100 are numbers, and 55 (ㅠㅠ) takes a
switch key. 00 and more is ㅋㅋ after Korean, when the word starts after a space or Hangul (not
1,000 or 10:00), and has ㅋㅋ as a reading to switch to anywhere.

**3-set's symbols** (#35). The keys that type a digit or symbol on 3-set where QWERTY types another
(`Sebeolsik.symbol(for:)`; 최종's ⇧B ?, ⇧/ !, ⇧H–⇧P digits, [ (; 390's ⇧B !, ⇧M ⇧, ⇧. 1 2 3) type 3-set's
straight after a word that reads as Korean (no stray jamo but ㅋㅋ-like runs) and in the symbols
that follow it (지냈어?!, 그래...?). The word goes in with it, and a switch key right after takes both
back to the keys as typed (`Committed.typedBoundary`: 지냈어? → ldhr2jtB); in a `holdSpace` app the
symbol is held as QWERTY's are. At a word's start, after a space, after English and in a URL the
keys are QWERTY's (Bob, iPhone). Of en_50k's top 20,000 words with each such key after them, only
those that read as Korean on their own change (mr? 해!, as mr is 해 already).

**390.** The same jamo on the letters and the digit row, so English and most Korean keys read the
same; the shifted keys differ (⇧1 ㅈ, ⇧E ㅋ, ⇧D ㄺ, ⇧F ㄲ, ⇧C ㄻ, ⇧V ㅀ, ⇧R ㅒ), and ㄳ ㄵ ㄼ ㄽ ㄾ ㄿ
are two finals in a row (앉 jfs!), which the composer's `finalCombos` joins. Its unshifted symbols
are QWERTY's (` is ₩) and its digits a keypad under the right hand.

**Accuracy** (eval.tsv, Korean rows typed again from their reading with `tools/layout_eval.py
sebeolsikFinal`): 99.40% (English → Korean 10, Korean → English 3, against 2-set's 5 and 4), and
the same on 390, whose keys differ in 52 rows; typed through a session, 1,984 of 1,987 Korean rows
come out right on either, the Japanese rows exactly as on
2-set, and of en_50k's top 20,000 words 64 change (2-set: 128): mr 해, pc 페, mm ㅎㅎ, 2nd 2시.

**Not covered.** Words learned on one Korean layout are learned again on another (their keys
differ). 3-set's symbols at a word's start (“ after a space) type as on QWERTY; full-width digits
after Japanese don't apply to digits that went into a word.
