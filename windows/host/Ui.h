// What the host draws by the caret, besides the strip (Strip.h): the word for classic apps and the
// pause indicator (PauseHUD). Topmost windows that never take the focus from the app.
#pragma once

#include "../common/Common.h"

#include <functional>
#include <string>
#include <vector>

namespace araso {

/// Colors and metrics that follow Windows' light or dark mode and the monitor's DPI.
namespace ui {

struct Theme {
    bool dark;
    COLORREF background;
    COLORREF text;
    COLORREF secondary;
    COLORREF accent;
    COLORREF accentText;
    COLORREF border;
};

Theme CurrentTheme();
UINT DpiAt(const RECT &rect);
inline int Scale(int value, UINT dpi) { return MulDiv(value, static_cast<int>(dpi), 96); }
/// The UI font (Segoe UI, which Windows links to Malgun Gothic and Yu Gothic for Hangul and kana).
HFONT Font(UINT dpi, int pointsTimesTen = 100, bool bold = false);
RECT WorkAreaAt(const RECT &rect);
/// Windows 11's rounded corners and shadow for a popup.
void Round(HWND window);

}  // namespace ui

/// The word being typed, drawn at the caret, underlined: for classic apps (IMM32), which end a
/// Korean input method's composition at once, so the word can't be composed in the text.
class WordWindow {
public:
    /// Shows `text` over the caret's line (screen pixels).
    void Show(const std::wstring &text, const RECT &caret);
    void Hide();
    /// Where it is on screen, while shown (the strip goes under it).
    bool Shown(RECT &rect) const;

private:
    HWND window_ = nullptr;
    std::wstring text_;
    UINT dpi_ = 96;

    void Paint(HDC dc);
    static LRESULT CALLBACK Proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
};

class PauseHud {
public:
    /// Araso's icon under the caret for a moment, struck through when paused.
    void Show(bool paused, const RECT &caret);

private:
    HWND window_ = nullptr;
    bool paused_ = false;
    int alpha_ = 255;
    UINT dpi_ = 96;

    static LRESULT CALLBACK Proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
};

}  // namespace araso
