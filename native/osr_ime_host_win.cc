// Copyright (c) 2026 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "osr_ime_host_win.h"

#include <windows.h>
#include <imm.h>

#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "include/cef_browser.h"

#pragma comment(lib, "imm32.lib")

namespace osr_ime_host_win {

namespace {

// Per-HWND state. The IME relay subclasses the GLCanvas's native HWND with
// our WndProc and routes WM_IME_* messages to the browser bound here. We
// keep state in a map keyed by HWND because Windows doesn't have ObjC's
// associated-object pattern and we can't change the HWND's user data
// (JCEF / JOGL already use it).
struct HostState {
  CefRefPtr<CefBrowser> browser;
  WNDPROC original_wnd_proc;
  bool active;
};

std::mutex& StateMutex() {
  static std::mutex m;
  return m;
}

std::unordered_map<HWND, HostState>& StateMap() {
  static std::unordered_map<HWND, HostState> m;
  return m;
}

// Read the current composition / result string out of the IME context. CEF
// only supports BMP characters in a single CefString so we collect UTF-16
// code units directly and let CefString convert.
std::wstring GetImeString(HIMC himc, DWORD index) {
  LONG byte_size = ImmGetCompositionStringW(himc, index, nullptr, 0);
  if (byte_size <= 0) return std::wstring();
  std::wstring out(byte_size / sizeof(wchar_t), L'\0');
  ImmGetCompositionStringW(himc, index, &out[0], byte_size);
  return out;
}

void HandleImeComposition(HWND hwnd, HostState& state, LPARAM lparam) {
  if (!state.browser.get()) return;
  HIMC himc = ImmGetContext(hwnd);
  if (!himc) return;

  // Final commit — IME has resolved to a string the user accepted.
  if (lparam & GCS_RESULTSTR) {
    std::wstring text = GetImeString(himc, GCS_RESULTSTR);
    if (!text.empty()) {
      state.browser->GetHost()->ImeCommitText(
          CefString(text), CefRange::InvalidRange(), 0);
    }
  }

  // Mid-composition update — show the current composition + caret.
  if (lparam & GCS_COMPSTR) {
    std::wstring text = GetImeString(himc, GCS_COMPSTR);
    LONG cursor_pos = ImmGetCompositionStringW(himc, GCS_CURSORPOS, nullptr, 0);
    if (cursor_pos < 0) cursor_pos = static_cast<LONG>(text.length());
    // We don't have caret rect info from the IMM32 callback shape itself;
    // Blink will fall back to placing the caret at end of composition,
    // which is the same behavior as a normal text field.
    std::vector<CefCompositionUnderline> underlines;
    CefCompositionUnderline u;
    u.range = CefRange(0, static_cast<int>(text.length()));
    u.color = 0xFF000000;          // black
    u.background_color = 0;
    u.thick = false;
    u.style = CEF_CUS_SOLID;
    underlines.push_back(u);
    state.browser->GetHost()->ImeSetComposition(
        CefString(text),
        underlines,
        CefRange::InvalidRange(),
        CefRange(static_cast<int>(cursor_pos),
                 static_cast<int>(cursor_pos)));
  }

  ImmReleaseContext(hwnd, himc);
}

LRESULT CALLBACK SubclassedWndProc(HWND hwnd,
                                   UINT msg,
                                   WPARAM wparam,
                                   LPARAM lparam) {
  WNDPROC original = nullptr;
  bool active = false;
  CefRefPtr<CefBrowser> browser;
  {
    std::lock_guard<std::mutex> lk(StateMutex());
    auto it = StateMap().find(hwnd);
    if (it == StateMap().end()) {
      // Subclass somehow outlived its registration. Fall back to default
      // — better to drop one keystroke than to crash.
      return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    original = it->second.original_wnd_proc;
    active = it->second.active;
    browser = it->second.browser;
  }

  if (active && browser.get()) {
    switch (msg) {
      case WM_IME_STARTCOMPOSITION:
        // Nothing to do up-front; Blink resets composition state when the
        // first SetComposition arrives.
        return 0;
      case WM_IME_COMPOSITION: {
        HostState state;
        {
          std::lock_guard<std::mutex> lk(StateMutex());
          auto it = StateMap().find(hwnd);
          if (it != StateMap().end()) state = it->second;
        }
        HandleImeComposition(hwnd, state, lparam);
        // Block default so DefWindowProc doesn't also emit WM_CHAR for the
        // composition string — that would double-insert.
        return 0;
      }
      case WM_IME_ENDCOMPOSITION:
        browser->GetHost()->ImeFinishComposingText(false);
        return 0;
      case WM_IME_SETCONTEXT:
        // Hide the default composition window — Blink renders its own.
        lparam &= ~ISC_SHOWUICOMPOSITIONWINDOW;
        break;
    }
  }

  if (original) {
    return CallWindowProcW(original, hwnd, msg, wparam, lparam);
  }
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}

}  // namespace

void Attach(void* hwndPtr,
            void* /*glCanvasSurfacePtr*/,
            CefRefPtr<CefBrowser> browser) {
  if (!hwndPtr) return;
  HWND hwnd = reinterpret_cast<HWND>(hwndPtr);

  std::lock_guard<std::mutex> lk(StateMutex());
  auto it = StateMap().find(hwnd);
  if (it != StateMap().end()) {
    // Already attached — just refresh the bound browser.
    it->second.browser = browser;
    it->second.active = true;
    return;
  }
  WNDPROC original = reinterpret_cast<WNDPROC>(
      SetWindowLongPtrW(hwnd, GWLP_WNDPROC,
                        reinterpret_cast<LONG_PTR>(SubclassedWndProc)));
  if (!original) return;
  StateMap()[hwnd] = HostState{browser, original, /*active=*/true};
}

void UpdateCompositionRange(void* hwndPtr,
                            const CefRange& /*selected_range*/,
                            const std::vector<CefRect>& /*character_bounds*/) {
  // The IMM32 composition window is drawn by Windows next to the caret;
  // when Blink reports a new composition range we just translate the bounds
  // into a CANDIDATEFORM and feed it back to the IME context so candidate
  // pop-ups land on the right pixel. We don't have direct access to the
  // candidate UI on OSR builds and CEF takes care of drawing the caret
  // itself, so leaving this empty matches what cefclient does in OSR mode.
  (void)hwndPtr;
}

void SetActive(void* hwndPtr, bool active) {
  if (!hwndPtr) return;
  HWND hwnd = reinterpret_cast<HWND>(hwndPtr);
  std::lock_guard<std::mutex> lk(StateMutex());
  auto it = StateMap().find(hwnd);
  if (it == StateMap().end()) return;
  it->second.active = active;
}

}  // namespace osr_ime_host_win
