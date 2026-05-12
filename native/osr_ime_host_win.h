// Copyright (c) 2026 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#ifndef JCEF_NATIVE_OSR_IME_HOST_WIN_H_
#define JCEF_NATIVE_OSR_IME_HOST_WIN_H_
#pragma once

#include <vector>

#include "include/cef_browser.h"

// Windows IME relay for OSR-mode CEF browsers, mirroring osr_ime_host_mac on
// macOS. Uses IMM32 (Windows' input method API) rather than TSF — IMM32 is
// simpler, ships in every Windows build since XP, and is what CEF's own
// cefclient OSR sample uses. For Korean / Japanese / Chinese composition
// input we hook the JOGL GLCanvas window's WndProc and translate
// `WM_IME_*` messages into `CefBrowserHost::ImeSetComposition` /
// `ImeCommitText` etc.
//
// The HWND is passed as `void*` so this header is includable from pure C++
// translation units (CefBrowser_N.cpp); the .cc side casts it back to HWND.
namespace osr_ime_host_win {

// Installs the IME relay onto the HWND that hosts the GLCanvas. hwndPtr is
// the GLCanvas's native HWND (obtained via JAWT_Win32DrawingSurfaceInfo).
// glCanvasSurfacePtr is reserved for parity with the macOS signature and is
// currently unused on Windows.
void Attach(void* hwndPtr,
            void* glCanvasSurfacePtr,
            CefRefPtr<CefBrowser> browser);

// Updates the caret rect that the IME composition window anchors to.
// Should be called from CefRenderHandler::OnImeCompositionRangeChanged.
void UpdateCompositionRange(void* hwndPtr,
                            const CefRange& selected_range,
                            const std::vector<CefRect>& character_bounds);

// Toggles whether the IME relay is the active focus target for the browser.
// `false` lets other Swing/AWT text inputs in the same window receive
// keystrokes again.
void SetActive(void* hwndPtr, bool active);

}  // namespace osr_ime_host_win

#endif  // JCEF_NATIVE_OSR_IME_HOST_WIN_H_
