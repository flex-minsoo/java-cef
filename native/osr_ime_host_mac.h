// Copyright (c) 2026 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#ifndef JCEF_NATIVE_OSR_IME_HOST_MAC_H_
#define JCEF_NATIVE_OSR_IME_HOST_MAC_H_
#pragma once

#include <vector>

#include "include/cef_browser.h"

// Attaches an NSTextInputClient-routing helper NSView onto the JOGL GLCanvas's
// underlying NSView for an OSR browser. macOS sends IME (e.g. Korean Hangul)
// composition events to whichever NSView is first responder AND advertises an
// NSTextInputContext via `-inputContext`. JOGL's GLCanvas does neither, so we
// add a thin child NSView (`OsrImeHostView`) that:
//   - covers the parent (fills its bounds, autoresize)
//   - returns a valid NSTextInputContext routing to CefTextInputClientOSRMac
//   - receives keyDown/keyUp via Cocoa's responder chain
//   - forwards mouse events back to the parent so the OSR pixels under the
//     overlay still receive clicks normally
//
// The NSView is passed as void* so this header is includable from pure C++
// translation units (CefBrowser_N.cpp); the .mm side casts it back to NSView*.
namespace osr_ime_host_mac {

// Installs the IME relay onto the NSWindow that hosts the GLCanvas. We add
// our helper NSView as a sibling of the GLCanvas's content view (under the
// window's contentView) and make it first responder. nsWindowPtr is the
// NSWindow*; glCanvasSurfacePtr is the JOGL surface handle used for size
// reference (optional but useful for laying out the host view).
void Attach(void* nsWindowPtr,
            void* glCanvasSurfacePtr,
            CefRefPtr<CefBrowser> browser);

// Updates the cached caret rect that NSTextInputClient reports back to AppKit
// (firstRectForCharacterRange:). Should be called from
// CefRenderHandler::OnImeCompositionRangeChanged.
void UpdateCompositionRange(void* nsWindowPtr,
                            const CefRange& selected_range,
                            const std::vector<CefRect>& character_bounds);

// Toggles whether the IME host actively reclaims first-responder when AWT
// steals it. Pass `false` when the OSR area is no longer the user's focus
// target (e.g. AgentHub tab unmounted) so other text inputs in the same
// window can receive keystrokes again.
void SetActive(void* nsWindowPtr, bool active);

}  // namespace osr_ime_host_mac

#endif  // JCEF_NATIVE_OSR_IME_HOST_MAC_H_
