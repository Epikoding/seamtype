#include "Ui.h"

#include "resource.h"

#include <dwmapi.h>
#include <objidl.h>
#include <gdiplus.h>
#include <shellscalingapi.h>

#include <algorithm>

namespace araso {

namespace ui {

namespace {

DWORD ReadDword(HKEY root, const wchar_t *path, const wchar_t *name, DWORD fallback) {
    DWORD value = 0, size = sizeof value;
    if (RegGetValueW(root, path, name, RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS) return value;
    return fallback;
}

}  // namespace

Theme CurrentTheme() {
    bool dark = ReadDword(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                          L"AppsUseLightTheme", 1) == 0;
    DWORD colorization = 0;
    BOOL opaque = FALSE;
    COLORREF accent = RGB(0, 95, 184);
    if (SUCCEEDED(DwmGetColorizationColor(&colorization, &opaque))) {
        accent = RGB((colorization >> 16) & 0xFF, (colorization >> 8) & 0xFF, colorization & 0xFF);
    }
    Theme theme;
    theme.dark = dark;
    theme.background = dark ? RGB(44, 44, 44) : RGB(249, 249, 249);
    theme.text = dark ? RGB(255, 255, 255) : RGB(26, 26, 26);
    theme.secondary = dark ? RGB(170, 170, 170) : RGB(110, 110, 110);
    theme.accent = accent;
    theme.accentText = RGB(255, 255, 255);
    theme.border = dark ? RGB(70, 70, 70) : RGB(220, 220, 220);
    return theme;
}

UINT DpiAt(const RECT &rect) {
    HMONITOR monitor = MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST);
    UINT x = 96, y = 96;
    if (FAILED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &x, &y))) return 96;
    return x;
}

HFONT Font(UINT dpi, int pointsTimesTen, bool bold) {
    NONCLIENTMETRICSW metrics = {sizeof metrics};
    SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof metrics, &metrics, 0, dpi);
    LOGFONTW font = metrics.lfMessageFont;
    font.lfHeight = -MulDiv(pointsTimesTen, static_cast<int>(dpi), 720);
    if (bold) font.lfWeight = FW_SEMIBOLD;
    font.lfQuality = CLEARTYPE_QUALITY;
    return CreateFontIndirectW(&font);
}

RECT WorkAreaAt(const RECT &rect) {
    MONITORINFO info = {sizeof info};
    GetMonitorInfoW(MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST), &info);
    return info.rcWork;
}

void Round(HWND window) {
    // DWMWA_WINDOW_CORNER_PREFERENCE (33) = DWMWCP_ROUNDSMALL (3); ignored before Windows 11.
    DWORD preference = 3;
    DwmSetWindowAttribute(window, 33, &preference, sizeof preference);
}

void FillRounded(HDC dc, const RECT &rect, int radius, COLORREF color) {
    Gdiplus::Graphics graphics(dc);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    Gdiplus::SolidBrush brush(Gdiplus::Color(255, GetRValue(color), GetGValue(color), GetBValue(color)));
    Gdiplus::GraphicsPath path;
    float x = static_cast<float>(rect.left), y = static_cast<float>(rect.top);
    float w = static_cast<float>(rect.right - rect.left), h = static_cast<float>(rect.bottom - rect.top);
    float d = static_cast<float>(radius * 2);
    path.AddArc(x, y, d, d, 180, 90);
    path.AddArc(x + w - d, y, d, d, 270, 90);
    path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
    path.AddArc(x, y + h - d, d, d, 90, 90);
    path.CloseFigure();
    graphics.FillPath(&brush, &path);
}

}  // namespace ui

namespace {

const wchar_t *kCandidateClass = L"ArasoCandidates";
const wchar_t *kPauseClass = L"ArasoPauseHud";
const wchar_t *kWordClass = L"ArasoWord";

void RegisterOnce(const wchar_t *name, WNDPROC proc, bool shadow) {
    WNDCLASSEXW cls = {sizeof cls};
    if (GetClassInfoExW(GetModuleHandleW(nullptr), name, &cls)) return;
    cls.style = CS_HREDRAW | CS_VREDRAW | (shadow ? CS_DROPSHADOW : 0);
    cls.lpfnWndProc = proc;
    cls.hInstance = GetModuleHandleW(nullptr);
    cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    cls.lpszClassName = name;
    RegisterClassExW(&cls);
}

HWND MakePopup(const wchar_t *name, void *owner) {
    HWND window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED, name, L"",
                                  WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (window) {
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(owner));
        SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA);
        ui::Round(window);
    }
    return window;
}

/// Puts a window of `size` under `anchor`, or above it when there is no room below, inside the
/// monitor's work area.
POINT Place(const RECT &anchor, SIZE size, int gap) {
    RECT work = ui::WorkAreaAt(anchor);
    POINT origin = {anchor.left, anchor.bottom + gap};
    if (origin.y + size.cy > work.bottom) origin.y = anchor.top - gap - size.cy;
    origin.x = std::max(work.left, std::min(origin.x, static_cast<LONG>(work.right - size.cx)));
    origin.y = std::max(work.top, std::min(origin.y, static_cast<LONG>(work.bottom - size.cy)));
    return origin;
}

}  // namespace

// MARK: - The word at the caret

void WordWindow::Show(const std::wstring &text, const RECT &caret) {
    if (text.empty() || caret.bottom <= caret.top) return Hide();
    RegisterOnce(kWordClass, Proc, true);
    if (!window_) window_ = MakePopup(kWordClass, this);
    if (!window_) return;
    text_ = text;
    dpi_ = ui::DpiAt(caret);
    HDC screen = GetDC(nullptr);
    HFONT font = ui::Font(dpi_, 110);
    HGDIOBJ old = SelectObject(screen, font);
    SIZE extent = {};
    GetTextExtentPoint32W(screen, text_.c_str(), static_cast<int>(text_.size()), &extent);
    SelectObject(screen, old);
    DeleteObject(font);
    ReleaseDC(nullptr, screen);
    int pad = ui::Scale(6, dpi_);
    SIZE size = {extent.cx + 2 * pad, std::max(static_cast<LONG>(caret.bottom - caret.top), extent.cy) + pad};
    // Where the word would be: from the caret, over its line.
    RECT work = ui::WorkAreaAt(caret);
    POINT origin = {caret.left, caret.top - pad / 2};
    origin.x = std::max(work.left, std::min(origin.x, static_cast<LONG>(work.right - size.cx)));
    origin.y = std::max(work.top, std::min(origin.y, static_cast<LONG>(work.bottom - size.cy)));
    SetWindowPos(window_, HWND_TOPMOST, origin.x, origin.y, size.cx, size.cy, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(window_, nullptr, FALSE);
}

void WordWindow::Hide() {
    if (window_) ShowWindow(window_, SW_HIDE);
    text_.clear();
}

bool WordWindow::Shown(RECT &rect) const {
    if (!window_ || !IsWindowVisible(window_)) return false;
    return GetWindowRect(window_, &rect) != FALSE;
}

void WordWindow::Paint(HDC target) {
    RECT client;
    GetClientRect(window_, &client);
    HDC dc = CreateCompatibleDC(target);
    HBITMAP bitmap = CreateCompatibleBitmap(target, client.right, client.bottom);
    HGDIOBJ oldBitmap = SelectObject(dc, bitmap);
    ui::Theme theme = ui::CurrentTheme();
    HBRUSH background = CreateSolidBrush(theme.background);
    FillRect(dc, &client, background);
    DeleteObject(background);
    HFONT font = ui::Font(dpi_, 110);
    HGDIOBJ oldFont = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, theme.text);
    RECT text = client;
    InflateRect(&text, -ui::Scale(6, dpi_), 0);
    DrawTextW(dc, text_.c_str(), -1, &text, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
    // Underlined, as a composition is in the text.
    SIZE extent = {};
    GetTextExtentPoint32W(dc, text_.c_str(), static_cast<int>(text_.size()), &extent);
    int y = (client.bottom + extent.cy) / 2;
    RECT line = {text.left, y - ui::Scale(1, dpi_), text.left + extent.cx, y};
    HBRUSH underline = CreateSolidBrush(theme.text);
    FillRect(dc, &line, underline);
    DeleteObject(underline);
    BitBlt(target, 0, 0, client.right, client.bottom, dc, 0, 0, SRCCOPY);
    SelectObject(dc, oldFont);
    DeleteObject(font);
    SelectObject(dc, oldBitmap);
    DeleteObject(bitmap);
    DeleteDC(dc);
}

LRESULT CALLBACK WordWindow::Proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    auto *self = reinterpret_cast<WordWindow *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    switch (message) {
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(window, &paint);
        if (self) self->Paint(dc);
        EndPaint(window, &paint);
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    default:
        return DefWindowProcW(window, message, wParam, lParam);
    }
}

// MARK: - Candidates

int CandidateWindow::RowHeight() const { return ui::Scale(28, dpi_); }

void CandidateWindow::Show(const std::vector<std::wstring> &texts, int selected, const RECT &word,
                           std::function<void(int)> choose) {
    if (texts.empty()) return Hide();
    RegisterOnce(kCandidateClass, Proc, true);
    if (!window_) window_ = MakePopup(kCandidateClass, this);
    if (!window_) return;
    bool sameList = texts == texts_ && IsWindowVisible(window_);
    texts_ = texts;
    selected_ = std::max(0, std::min(selected, static_cast<int>(texts.size()) - 1));
    choose_ = std::move(choose);
    if (!sameList) first_ = 0;
    if (selected_ < first_) first_ = selected_;
    if (selected_ >= first_ + kRows) first_ = selected_ - kRows + 1;
    dpi_ = ui::DpiAt(word);

    // As wide as the widest candidate with its number.
    HDC screen = GetDC(nullptr);
    HFONT font = ui::Font(dpi_, 110);
    HGDIOBJ old = SelectObject(screen, font);
    int width = ui::Scale(120, dpi_);
    for (const auto &text : texts_) {
        SIZE extent = {};
        GetTextExtentPoint32W(screen, text.c_str(), static_cast<int>(text.size()), &extent);
        width = std::max(width, static_cast<int>(extent.cx) + ui::Scale(56, dpi_));
    }
    SelectObject(screen, old);
    DeleteObject(font);
    ReleaseDC(nullptr, screen);
    int rows = std::min(kRows, static_cast<int>(texts_.size()));
    SIZE size = {std::min(width, ui::Scale(520, dpi_)), rows * RowHeight() + ui::Scale(8, dpi_)};
    POINT origin = Place(word, size, ui::Scale(4, dpi_));
    SetWindowPos(window_, HWND_TOPMOST, origin.x, origin.y, size.cx, size.cy, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(window_, nullptr, FALSE);
}

void CandidateWindow::Hide() {
    if (window_) ShowWindow(window_, SW_HIDE);
    texts_.clear();
}

void CandidateWindow::Paint(HDC target) {
    RECT client;
    GetClientRect(window_, &client);
    HDC dc = CreateCompatibleDC(target);
    HBITMAP bitmap = CreateCompatibleBitmap(target, client.right, client.bottom);
    HGDIOBJ oldBitmap = SelectObject(dc, bitmap);
    ui::Theme theme = ui::CurrentTheme();
    HBRUSH background = CreateSolidBrush(theme.background);
    FillRect(dc, &client, background);
    DeleteObject(background);

    HFONT font = ui::Font(dpi_, 110);
    HFONT fine = ui::Font(dpi_, 85);
    SetBkMode(dc, TRANSPARENT);
    int pad = ui::Scale(4, dpi_);
    int rows = std::min(kRows, static_cast<int>(texts_.size()) - first_);
    for (int row = 0; row < rows; row++) {
        int index = first_ + row;
        RECT line = {pad, pad + row * RowHeight(), client.right - pad, pad + (row + 1) * RowHeight()};
        bool on = index == selected_;
        if (on) ui::FillRounded(dc, line, ui::Scale(4, dpi_), theme.accent);
        // The number to the left, as macOS's candidate window has (1–9 on the page).
        RECT number = line;
        number.left += ui::Scale(8, dpi_);
        number.right = number.left + ui::Scale(18, dpi_);
        SelectObject(dc, fine);
        SetTextColor(dc, on ? theme.accentText : theme.secondary);
        std::wstring digit = std::to_wstring(row + 1);
        DrawTextW(dc, digit.c_str(), -1, &number, DT_SINGLELINE | DT_VCENTER | DT_CENTER);
        RECT text = line;
        text.left = number.right + ui::Scale(8, dpi_);
        text.right -= ui::Scale(8, dpi_);
        SelectObject(dc, font);
        SetTextColor(dc, on ? theme.accentText : theme.text);
        DrawTextW(dc, texts_[index].c_str(), -1, &text, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
    }
    // More above or below: a thin bar at the right edge.
    if (static_cast<int>(texts_.size()) > kRows) {
        int total = static_cast<int>(texts_.size());
        int track = client.bottom - 2 * pad;
        RECT bar = {client.right - ui::Scale(3, dpi_), pad + track * first_ / total, client.right - ui::Scale(1, dpi_),
                    pad + track * std::min(total, first_ + kRows) / total};
        ui::FillRounded(dc, bar, ui::Scale(1, dpi_), theme.secondary);
    }
    BitBlt(target, 0, 0, client.right, client.bottom, dc, 0, 0, SRCCOPY);
    SelectObject(dc, oldBitmap);
    DeleteObject(bitmap);
    DeleteObject(font);
    DeleteObject(fine);
    DeleteDC(dc);
}

LRESULT CALLBACK CandidateWindow::Proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    auto *self = reinterpret_cast<CandidateWindow *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    switch (message) {
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(window, &paint);
        if (self) self->Paint(dc);
        EndPaint(window, &paint);
        return 0;
    }
    case WM_LBUTTONUP:
        if (self && self->choose_) {
            int y = static_cast<short>(HIWORD(lParam)) - ui::Scale(4, self->dpi_);
            int index = self->first_ + y / self->RowHeight();
            if (y >= 0 && index < static_cast<int>(self->texts_.size())) self->choose_(index);
        }
        return 0;
    case WM_MOUSEWHEEL:
        if (self) {
            int step = GET_WHEEL_DELTA_WPARAM(wParam) > 0 ? -1 : 1;
            int last = std::max(0, static_cast<int>(self->texts_.size()) - kRows);
            self->first_ = std::max(0, std::min(last, self->first_ + step));
            InvalidateRect(window, nullptr, FALSE);
        }
        return 0;
    case WM_ERASEBKGND:
        return 1;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

// MARK: - Pause indicator

namespace {
constexpr UINT_PTR kFadeTimer = 1;
}

void PauseHud::Show(bool paused, const RECT &caret) {
    if (caret.bottom <= caret.top) return;
    RegisterOnce(kPauseClass, Proc, false);
    if (!window_) window_ = MakePopup(kPauseClass, this);
    if (!window_) return;
    paused_ = paused;
    dpi_ = ui::DpiAt(caret);
    alpha_ = 255;
    // The size and gap of Windows' own input indicator by the caret.
    int side = ui::Scale(28, dpi_);
    SIZE size = {side, side};
    POINT origin = Place(caret, size, ui::Scale(6, dpi_));
    SetLayeredWindowAttributes(window_, 0, 255, LWA_ALPHA);
    SetWindowPos(window_, HWND_TOPMOST, origin.x, origin.y, side, side, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(window_, nullptr, TRUE);
    // Stays a moment, then fades.
    SetTimer(window_, kFadeTimer, 800, nullptr);
}

LRESULT CALLBACK PauseHud::Proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    auto *self = reinterpret_cast<PauseHud *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    switch (message) {
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_NCHITTEST:
        return HTTRANSPARENT;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(window, &paint);
        if (self) {
            RECT client;
            GetClientRect(window, &client);
            ui::Theme theme = ui::CurrentTheme();
            HBRUSH background = CreateSolidBrush(theme.background);
            FillRect(dc, &client, background);
            DeleteObject(background);
            int side = client.right - ui::Scale(8, self->dpi_);
            HICON icon = static_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr),
                                                       MAKEINTRESOURCEW(self->paused_ ? IDI_HOST_PAUSED : IDI_HOST),
                                                       IMAGE_ICON, side, side, 0));
            if (icon) {
                DrawIconEx(dc, ui::Scale(4, self->dpi_), ui::Scale(4, self->dpi_), icon, side, side, 0, nullptr, DI_NORMAL);
                DestroyIcon(icon);
            }
        }
        EndPaint(window, &paint);
        return 0;
    }
    case WM_TIMER:
        if (self && wParam == kFadeTimer) {
            KillTimer(window, kFadeTimer);
            SetTimer(window, kFadeTimer + 1, 16, nullptr);
        } else if (self) {
            self->alpha_ -= 32;
            if (self->alpha_ <= 0) {
                KillTimer(window, kFadeTimer + 1);
                ShowWindow(window, SW_HIDE);
            } else {
                SetLayeredWindowAttributes(window, 0, static_cast<BYTE>(self->alpha_), LWA_ALPHA);
            }
        }
        return 0;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

// MARK: - Readings

namespace {
const wchar_t *kReadingsClass = L"ArasoReadings";
const wchar_t *kLearnedClass = L"ArasoLearned";
constexpr UINT_PTR kFrameTimer = 7;
}

void ReadingsWindow::Show(const std::vector<Row> &rows, int selected, int pick, int once, const RECT &anchor) {
    if (rows.empty() || anchor.bottom <= anchor.top) return Hide();
    RegisterOnce(kReadingsClass, Proc, true);
    if (!window_) window_ = MakePopup(kReadingsClass, this);
    if (!window_) return;
    rows_ = rows;
    selected_ = selected;
    pick_ = pick;
    once_ = once;
    dpi_ = ui::DpiAt(anchor);
    HDC screen = GetDC(nullptr);
    HFONT font = ui::Font(dpi_, 100), bold = ui::Font(dpi_, 80, true);
    HGDIOBJ old = SelectObject(screen, bold);
    int tags = 0, texts = 0;
    for (const auto &row : rows_) {
        SIZE extent = {};
        GetTextExtentPoint32W(screen, row.tag.c_str(), static_cast<int>(row.tag.size()), &extent);
        tags = std::max(tags, static_cast<int>(extent.cx));
    }
    SelectObject(screen, font);
    for (const auto &row : rows_) {
        SIZE extent = {};
        GetTextExtentPoint32W(screen, row.text.c_str(), static_cast<int>(row.text.size()), &extent);
        texts = std::max(texts, static_cast<int>(extent.cx));
    }
    SelectObject(screen, old);
    DeleteObject(font);
    DeleteObject(bold);
    ReleaseDC(nullptr, screen);
    tagWidth_ = tags + ui::Scale(10, dpi_);
    int width = std::max(ui::Scale(96, dpi_), ui::Scale(14, dpi_) + tagWidth_ + texts + ui::Scale(16, dpi_));
    SIZE size = {width, static_cast<LONG>(rows_.size()) * ui::Scale(24, dpi_) + ui::Scale(6, dpi_)};
    POINT origin = Place(anchor, size, ui::Scale(4, dpi_));
    SetWindowPos(window_, HWND_TOPMOST, origin.x, origin.y, size.cx, size.cy, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(window_, nullptr, FALSE);
}

void ReadingsWindow::Hide() {
    if (window_) ShowWindow(window_, SW_HIDE);
    rows_.clear();
}

void ReadingsWindow::Paint(HDC target) {
    RECT client;
    GetClientRect(window_, &client);
    HDC dc = CreateCompatibleDC(target);
    HBITMAP bitmap = CreateCompatibleBitmap(target, client.right, client.bottom);
    HGDIOBJ oldBitmap = SelectObject(dc, bitmap);
    ui::Theme theme = ui::CurrentTheme();
    HBRUSH background = CreateSolidBrush(theme.background);
    FillRect(dc, &client, background);
    DeleteObject(background);
    HFONT font = ui::Font(dpi_, 100), tagFont = ui::Font(dpi_, 80), pillFont = ui::Font(dpi_, 80, true);
    SetBkMode(dc, TRANSPARENT);
    int inset = ui::Scale(3, dpi_), rowHeight = ui::Scale(24, dpi_);
    for (int k = 0; k < static_cast<int>(rows_.size()); k++) {
        RECT row = {inset, inset + k * rowHeight, client.right - inset, inset + (k + 1) * rowHeight};
        bool on = k == selected_;
        if (on) ui::FillRounded(dc, row, ui::Scale(5, dpi_), theme.accent);
        RECT tag = {row.left + ui::Scale(6, dpi_), row.top + (rowHeight - ui::Scale(16, dpi_)) / 2,
                    row.left + ui::Scale(6, dpi_) + tagWidth_, row.top + (rowHeight + ui::Scale(16, dpi_)) / 2};
        COLORREF tagInk = on ? theme.accentText : theme.secondary;
        if (k == pick_) {
            // The pill takes the ink, and the tag turns to what's under it.
            ui::FillRounded(dc, tag, ui::Scale(4, dpi_), on ? theme.accentText : theme.accent);
            tagInk = on ? theme.accent : theme.accentText;
        } else if (k == once_) {
            Gdiplus::Graphics graphics(dc);
            graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
            Gdiplus::Pen pen(Gdiplus::Color(255, GetRValue(tagInk), GetGValue(tagInk), GetBValue(tagInk)),
                             static_cast<float>(ui::Scale(13, dpi_)) / 10);
            pen.SetDashStyle(Gdiplus::DashStyleDot);
            graphics.DrawRectangle(&pen, static_cast<float>(tag.left), static_cast<float>(tag.top),
                                   static_cast<float>(tag.right - tag.left), static_cast<float>(tag.bottom - tag.top));
        }
        SelectObject(dc, k == pick_ ? pillFont : tagFont);
        SetTextColor(dc, tagInk);
        DrawTextW(dc, rows_[k].tag.c_str(), -1, &tag, DT_SINGLELINE | DT_VCENTER | DT_CENTER | DT_NOPREFIX);
        RECT text = row;
        text.left = tag.right + ui::Scale(6, dpi_);
        SelectObject(dc, font);
        SetTextColor(dc, on ? theme.accentText : theme.text);
        DrawTextW(dc, rows_[k].text.c_str(), -1, &text, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
    }
    BitBlt(target, 0, 0, client.right, client.bottom, dc, 0, 0, SRCCOPY);
    SelectObject(dc, oldBitmap);
    DeleteObject(bitmap);
    DeleteObject(font);
    DeleteObject(tagFont);
    DeleteObject(pillFont);
    DeleteDC(dc);
}

LRESULT CALLBACK ReadingsWindow::Proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    auto *self = reinterpret_cast<ReadingsWindow *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    switch (message) {
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_NCHITTEST:
        return HTTRANSPARENT;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(window, &paint);
        if (self) self->Paint(dc);
        EndPaint(window, &paint);
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

// MARK: - Correction line

void LearnedLine::Show(const std::string &learning, const RECT &word) {
    if (word.right - word.left < 4 || word.bottom <= word.top) return;
    WNDCLASSEXW cls = {sizeof cls};
    if (!GetClassInfoExW(GetModuleHandleW(nullptr), kLearnedClass, &cls)) {
        cls.lpfnWndProc = Proc;
        cls.hInstance = GetModuleHandleW(nullptr);
        cls.lpszClassName = kLearnedClass;
        RegisterClassExW(&cls);
    }
    if (!window_) {
        window_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT,
                                  kLearnedClass, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
        if (!window_) return;
        SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    }
    learning_ = learning;
    dpi_ = ui::DpiAt(word);
    width_ = word.right - word.left + 2;
    height_ = ui::Scale(4, dpi_);
    // Just under the letters, where the underline of the word being typed was.
    SetWindowPos(window_, HWND_TOPMOST, word.left - 1, word.bottom - height_ / 2, width_, height_,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    started_ = GetTickCount();
    Render();
    SetTimer(window_, kFrameTimer, 16, nullptr);
}

/// One frame: the line drawn (or taken back) by the time since it started, then a fade.
void LearnedLine::Render() {
    double t = (GetTickCount() - started_) / 1000.0;
    bool forGood = learning_ == "forGood", forgot = learning_ == "forgot";
    double stay = forgot ? 0.5 : 1.4, fade = 0.3;
    if (t > stay + fade) {
        KillTimer(window_, kFrameTimer);
        ShowWindow(window_, SW_HIDE);
        return;
    }
    auto ease = [](double x) { x = std::max(0.0, std::min(1.0, x)); return 1 - (1 - x) * (1 - x) * (1 - x); };
    double drawn = forgot ? 1 - ease((t - 0.08) / 0.42) : ease(t / (forGood ? 0.32 : 0.3));
    double alpha = t > stay ? std::max(0.0, 1 - (t - stay) / fade) : 1;

    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof info.bmiHeader;
    info.bmiHeader.biWidth = width_;
    info.bmiHeader.biHeight = -height_;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    void *bits = nullptr;
    HDC screen = GetDC(nullptr);
    HDC dc = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ old = SelectObject(dc, bitmap);
    {
        Gdiplus::Bitmap canvas(width_, height_, width_ * 4, PixelFormat32bppPARGB, static_cast<BYTE *>(bits));
        Gdiplus::Graphics graphics(&canvas);
        graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
        graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
        ui::Theme theme = ui::CurrentTheme();
        COLORREF ink = forGood ? theme.accent : theme.secondary;
        float thickness = static_cast<float>(ui::Scale(20, dpi_)) / 10;
        float y = height_ / 2.0f, end = 1 + static_cast<float>(drawn) * (width_ - 2);
        Gdiplus::Pen pen(Gdiplus::Color(255, GetRValue(ink), GetGValue(ink), GetBValue(ink)), thickness);
        pen.SetStartCap(Gdiplus::LineCapRound);
        pen.SetEndCap(Gdiplus::LineCapRound);
        if (learning_ == "once") pen.SetDashStyle(Gdiplus::DashStyleDot);
        if (end > 1.5f) graphics.DrawLine(&pen, 1.0f, y, end, y);
        if (forGood && t > 0.34 && t < 0.86) {
            // The streak of light, run along the line once it is down.
            float streak = static_cast<float>(ui::Scale(10, dpi_));
            float head = static_cast<float>(ease((t - 0.34) / 0.52)) * (width_ + streak);
            Gdiplus::Pen light(Gdiplus::Color(230, 255, 255, 255), thickness);
            float from = std::max(1.0f, head - streak), to = std::min(static_cast<float>(width_ - 1), head);
            if (to > from) graphics.DrawLine(&light, from, y, to, y);
        }
    }
    POINT source = {0, 0};
    SIZE size = {width_, height_};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, static_cast<BYTE>(alpha * 255), AC_SRC_ALPHA};
    UpdateLayeredWindow(window_, screen, nullptr, &size, dc, &source, 0, &blend, ULW_ALPHA);
    SelectObject(dc, old);
    DeleteObject(bitmap);
    DeleteDC(dc);
    ReleaseDC(nullptr, screen);
}

LRESULT CALLBACK LearnedLine::Proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    auto *self = reinterpret_cast<LearnedLine *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_TIMER && wParam == kFrameTimer && self) {
        self->Render();
        return 0;
    }
    if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace araso
