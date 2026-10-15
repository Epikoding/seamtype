# Seamtype

A macOS input method that reads QWERTY keystrokes and decides, per word, whether they are
English, Korean (2-set) or Japanese romaji. This glossary names the concepts the typing
logic and its documentation share.

## Language

**Word**:
The run of keystrokes between two boundaries, read as one language. Shown underlined while it is
being typed.
_Avoid_: token (except in engine scoring), composition

**Boundary** (경계 글자):
The single Space, ASCII symbol or digit that ends a word and goes into the text with it.
_Avoid_: delimiter, separator, terminator

**Held word** (잡아 둔 단어):
A word kept underlined together with its boundary, still treated as the word being typed, in an
app set to hold words. Only a Space or a symbol is held, never a digit. A switch key changes the
word and Delete takes back only the boundary.
_Avoid_: pending word, suspended word

**Switch key** (언어 바꾸기 키):
A key chosen per app that cycles the word being typed, or the word just committed, to its next
reading.
_Avoid_: toggle key, language key, Esc (it is only one possible switch key)

**Reading** (읽기):
One way of rendering a word's keys: English, English + Korean particle, Korean, Japanese.
_Avoid_: mode, interpretation

**Flip window** (확정한 뒤 고치기):
The moment right after a word was committed with its boundary, during which a switch key can
still change that word. It closes on any other key. Only apps that report the caret and the text
at it can offer it.
_Avoid_: undo window, post-commit edit
