// Copyright (c) 2026 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#import "osr_ime_host_mac.h"

#import "text_input_client_osr_mac.h"

#import <Carbon/Carbon.h>
#import <objc/runtime.h>

#include "include/cef_browser.h"

namespace {

// Returns the key event modifiers (control/shift/alt/meta etc) for a Cocoa
// event. Mirrors cefclient's BrowserOpenGLView -getModifiersForEvent: but only
// the bits we need for keyboard input.
int GetCefKeyboardModifiers(NSEvent* event) {
  NSUInteger flags = [event modifierFlags];
  int modifiers = 0;
  if (flags & NSEventModifierFlagControl)
    modifiers |= EVENTFLAG_CONTROL_DOWN;
  if (flags & NSEventModifierFlagShift)
    modifiers |= EVENTFLAG_SHIFT_DOWN;
  if (flags & NSEventModifierFlagOption)
    modifiers |= EVENTFLAG_ALT_DOWN;
  if (flags & NSEventModifierFlagCommand)
    modifiers |= EVENTFLAG_COMMAND_DOWN;
  if (flags & NSEventModifierFlagCapsLock)
    modifiers |= EVENTFLAG_CAPS_LOCK_ON;
  if ([event type] == NSEventTypeKeyDown ||
      [event type] == NSEventTypeKeyUp) {
    if ([event isARepeat]) {
      modifiers |= EVENTFLAG_IS_REPEAT;
    }
  }
  return modifiers;
}

// Map Cocoa virtual keycodes to Windows VK_ values for the alphabet — the
// only keys we currently care about for Cmd-shortcut dispatch. Layout-
// independent: Carbon's kVK_ANSI_* constants identify *physical* key
// positions, so kVK_ANSI_A is always the QWERTY 'A' position even on a
// Korean / Dvorak / etc. keyboard. Returns 0 for keys we don't handle.
int VKFromMacKeyCode(unsigned short keyCode) {
  switch (keyCode) {
    case kVK_ANSI_A: return 'A';
    case kVK_ANSI_B: return 'B';
    case kVK_ANSI_C: return 'C';
    case kVK_ANSI_D: return 'D';
    case kVK_ANSI_E: return 'E';
    case kVK_ANSI_F: return 'F';
    case kVK_ANSI_G: return 'G';
    case kVK_ANSI_H: return 'H';
    case kVK_ANSI_I: return 'I';
    case kVK_ANSI_J: return 'J';
    case kVK_ANSI_K: return 'K';
    case kVK_ANSI_L: return 'L';
    case kVK_ANSI_M: return 'M';
    case kVK_ANSI_N: return 'N';
    case kVK_ANSI_O: return 'O';
    case kVK_ANSI_P: return 'P';
    case kVK_ANSI_Q: return 'Q';
    case kVK_ANSI_R: return 'R';
    case kVK_ANSI_S: return 'S';
    case kVK_ANSI_T: return 'T';
    case kVK_ANSI_U: return 'U';
    case kVK_ANSI_V: return 'V';
    case kVK_ANSI_W: return 'W';
    case kVK_ANSI_X: return 'X';
    case kVK_ANSI_Y: return 'Y';
    case kVK_ANSI_Z: return 'Z';
    default: return 0;
  }
}

void FillKeyEventFromNSEvent(CefKeyEvent& keyEvent, NSEvent* event) {
  if ([event type] == NSEventTypeKeyDown || [event type] == NSEventTypeKeyUp) {
    NSString* s = [event characters];
    if ([s length] > 0) {
      keyEvent.character = [s characterAtIndex:0];
    }
    s = [event charactersIgnoringModifiers];
    if ([s length] > 0) {
      keyEvent.unmodified_character = [s characterAtIndex:0];
    }
  }
  if ([event type] == NSEventTypeFlagsChanged) {
    keyEvent.character = 0;
    keyEvent.unmodified_character = 0;
  }
  keyEvent.native_key_code = [event keyCode];
  keyEvent.modifiers = GetCefKeyboardModifiers(event);
}

}  // namespace

// Helper NSView installed as a child of the JOGL GLCanvas's NSView. Owns the
// CefTextInputClientOSRMac + NSTextInputContext and is the actual first
// responder for the OSR browser area. Mouse events are forwarded to the
// underlying parent so OSR pixel hit-testing continues to work via the existing
// JOGL/AWT path.
@interface OsrImeHostView : NSView {
  NSTextInputContext* textInputContext_;
  CefTextInputClientOSRMac* textInputClient_;
  CefRefPtr<CefBrowser> browser_;
  BOOL shouldReclaim_;
  id keyMonitor_;
}
- (instancetype)initWithBrowser:(CefRefPtr<CefBrowser>)browser
                          frame:(NSRect)frame;
- (void)detach;
- (CefTextInputClientOSRMac*)textInputClient;
- (void)setShouldReclaim:(BOOL)value;
- (BOOL)handleCmdShortcut:(NSEvent*)event;
@end

@implementation OsrImeHostView

- (instancetype)initWithBrowser:(CefRefPtr<CefBrowser>)browser
                          frame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    browser_ = browser;
    shouldReclaim_ = YES;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.wantsLayer = YES;
    // macOS's main menu has Cmd+C / Cmd+V / Cmd+A / Cmd+X / Cmd+Z registered
    // as key equivalents on its Edit submenu. NSApp dispatches key
    // equivalents to the menu BEFORE the responder chain's keyDown:, so our
    // -keyDown: never sees them. A local event monitor runs even earlier
    // than menu key-equivalent resolution, so we use it to forward those
    // shortcuts straight to CEF and swallow the event so the menu won't
    // also flash. Gated by shouldReclaim_ so it doesn't fire while the OSR
    // tab is unmounted — otherwise the user could Cmd+C in a different
    // Compose tab and we'd silently steal it.
    OsrImeHostView* __unsafe_unretained unsafeSelf = self;
    keyMonitor_ = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent*(NSEvent* event) {
                                       if (![unsafeSelf handleCmdShortcut:event]) {
                                         return event;
                                       }
                                       return nil;
                                     }];
  }
  return self;
}

- (BOOL)handleCmdShortcut:(NSEvent*)event {
  if (!shouldReclaim_) return NO;
  if (!browser_.get()) return NO;
  if (!([event modifierFlags] & NSEventModifierFlagCommand)) return NO;
  int vk = VKFromMacKeyCode([event keyCode]);
  if (vk == 0) return NO;
  BOOL shift = ([event modifierFlags] & NSEventModifierFlagShift) != 0;
  // selectAll / copy / cut / undo / redo all work fine via execCommand —
  // they only need DOM access. Paste is special: every modern Chromium
  // blocks `document.execCommand('paste')` for security (clipboard read
  // needs explicit user gesture + permission). The reliable path is to
  // feed Chromium the same native Cmd+V key event a real browser would
  // see; Blink's editor maps it to the platform paste flow which is
  // allowed because it comes from a trusted OS key event.
  if (vk == 'V') {
    // Paste bypasses Chromium's `execCommand('paste')` block by reading the
    // clipboard ourselves through NSPasteboard (we already have OS access)
    // and injecting the text via `execCommand('insertText', ...)` — which is
    // permitted because it doesn't expose clipboard contents to JS, it just
    // edits the focused field. This works identically inside contenteditable
    // areas, <input>, and <textarea>.
    NSString* clipText =
        [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (!clipText || [clipText length] == 0) return YES;
    CefRefPtr<CefFrame> frame = browser_->GetFocusedFrame();
    if (!frame) frame = browser_->GetMainFrame();
    if (!frame) return YES;
    // Escape for safe embedding in a JS string literal: backslash → \\, quote
    // → \', newline → \n, CR → \r, U+2028/U+2029 are not valid in JS string
    // literals so replace too. NSJSONSerialization gives us all of that for
    // free if we wrap the string in an array and slice.
    NSData* jsonData =
        [NSJSONSerialization dataWithJSONObject:@[ clipText ]
                                        options:0
                                          error:nullptr];
    NSString* json =
        [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    // `json` is e.g. ["hello\nworld"] — strip the brackets to get a quoted JS
    // string literal.
    NSString* quoted =
        [json substringWithRange:NSMakeRange(1, [json length] - 2)];
    NSString* script = [NSString
        stringWithFormat:@"document.execCommand('insertText', false, %@)",
                         quoted];
    frame->ExecuteJavaScript(CefString([script UTF8String]),
                             frame->GetURL(), 0);
#if !__has_feature(objc_arc)
    [json release];
#endif
    return YES;
  }
  const char* js = nullptr;
  switch (vk) {
    case 'A': js = "document.execCommand('selectAll')"; break;
    case 'C': js = "document.execCommand('copy')"; break;
    case 'X': js = "document.execCommand('cut')"; break;
    case 'Z': js = shift ? "document.execCommand('redo')"
                         : "document.execCommand('undo')"; break;
    default: return NO;
  }
  CefRefPtr<CefFrame> frame = browser_->GetFocusedFrame();
  if (!frame) frame = browser_->GetMainFrame();
  if (!frame) return NO;
  frame->ExecuteJavaScript(CefString(js), frame->GetURL(), 0);
  return YES;
}

// Resize to match the parent so mouseDown reaches us no matter where the user
// clicks. We unregister BEFORE the move (in -viewWillMoveToSuperview:) and
// re-register after, so that an in-flight notification can't fire on a stale
// super-view link during tear-down.
- (void)viewWillMoveToSuperview:(NSView*)newSuperview {
  [super viewWillMoveToSuperview:newSuperview];
  [[NSNotificationCenter defaultCenter]
      removeObserver:self
                name:NSViewFrameDidChangeNotification
              object:nil];
}

- (void)viewDidMoveToSuperview {
  [super viewDidMoveToSuperview];
  NSView* parent = [self superview];
  if (parent) {
    [self setFrame:[parent bounds]];
    [parent setPostsFrameChangedNotifications:YES];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(parentFrameChanged:)
               name:NSViewFrameDidChangeNotification
             object:parent];
  }
}

- (void)parentFrameChanged:(NSNotification*)notification {
  NSView* parent = [self superview];
  if (parent) {
    [self setFrame:[parent bounds]];
  }
}

- (void)dealloc {
  [self detach];
  if (keyMonitor_) {
    [NSEvent removeMonitor:keyMonitor_];
    keyMonitor_ = nil;
  }
  [[NSNotificationCenter defaultCenter] removeObserver:self];
#if !__has_feature(objc_arc)
  [textInputContext_ release];
  [textInputClient_ release];
  [super dealloc];
#endif
}

- (void)detach {
  if (textInputClient_) {
    [textInputClient_ detach];
  }
  browser_ = nullptr;
}

- (CefTextInputClientOSRMac*)textInputClient {
  // Lazily build the client on first access (which happens via -inputContext
  // when AppKit asks the first responder for its NSTextInputContext).
  if (!textInputClient_) {
    textInputClient_ =
        [[CefTextInputClientOSRMac alloc] initWithBrowser:browser_];
  }
  return textInputClient_;
}

- (NSTextInputContext*)inputContext {
  if (!textInputContext_) {
    textInputContext_ =
        [[NSTextInputContext alloc] initWithClient:[self textInputClient]];
  }
  return textInputContext_;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)becomeFirstResponder {
  return YES;
}

// AWT's responder chain steals first-responder whenever a mouse event lands
// on its NSView (e.g. when the user clicks the OSR area). We used to reclaim
// it unconditionally on the next runloop turn so IME routing stayed alive,
// but that turned the host into a "first-responder bully" — once installed
// it would yank focus back from any other view in the window (other Compose
// tabs, native text fields, …), so the user couldn't type anywhere else.
//
// Reclaim now only happens while [shouldReclaim_] is YES, which is gated by
// the Kotlin side via `osrSetImeActive(active=true)` and flipped to NO when
// the AgentHub tab is unmounted. This lets the IME host yield to whatever
// the user is interacting with next.
- (BOOL)resignFirstResponder {
  if (!shouldReclaim_) return [super resignFirstResponder];
  NSWindow* window = [self window];
  OsrImeHostView* strongSelf = self;
#if !__has_feature(objc_arc)
  [strongSelf retain];
#endif
  dispatch_async(dispatch_get_main_queue(), ^{
    if (strongSelf->shouldReclaim_ &&
        [window firstResponder] != strongSelf) {
      [window makeFirstResponder:strongSelf];
    }
#if !__has_feature(objc_arc)
    [strongSelf release];
#endif
  });
  return [super resignFirstResponder];
}

- (void)setShouldReclaim:(BOOL)value {
  shouldReclaim_ = value;
}

- (void)keyDown:(NSEvent*)event {
  if (!browser_.get() || !textInputContext_) {
    return;
  }
  if ([event type] == NSEventTypeFlagsChanged) {
    return;
  }
  // Command-modified keys (Cmd+C, Cmd+V, Cmd+A, …) must NOT pass through the
  // NSTextInputContext: AppKit can swallow them as menu shortcuts, and even
  // when it doesn't, the IME treats them as plain keystrokes and runs them
  // through `insertText:`, which would later land as a stray character in
  // the page. Forward them straight to CEF as a raw key-down + char pair so
  // the renderer can map them to the corresponding editing command.
  if ([event modifierFlags] & NSEventModifierFlagCommand) {
    CefKeyEvent keyEvent;
    FillKeyEventFromNSEvent(keyEvent, event);
    // CEF's renderer keys its editing-command dispatch off windows_key_code
    // (the platform-neutral VK_ value). On macOS we map Cocoa virtual key
    // codes — which describe the *physical* key position — to ANSI VK_*.
    // We do NOT derive this from `characters` because in non-ASCII keyboard
    // layouts (e.g. Korean IME mode) `characters` returns 'ㅁ' etc. and CEF
    // has no idea that means VK_A. Using the physical keycode makes Cmd+A
    // work regardless of layout, matching how a normal browser handles it.
    int vk = VKFromMacKeyCode([event keyCode]);
    if (vk != 0) keyEvent.windows_key_code = vk;
    // Cmd-modified keys are "system keys" on macOS — Chromium uses that flag
    // to decide whether to route the keystroke through Blink's editing
    // command dispatcher (which is what makes Cmd+C / Cmd+V / Cmd+A actually
    // copy/paste/select-all in the page). Without it the renderer treats the
    // event as a normal character keystroke and the shortcut never fires.
    keyEvent.is_system_key = true;
    keyEvent.type = KEYEVENT_RAWKEYDOWN;
    browser_->GetHost()->SendKeyEvent(keyEvent);
    keyEvent.type = KEYEVENT_CHAR;
    browser_->GetHost()->SendKeyEvent(keyEvent);
    return;
  }
  // cefclient's three-phase keyDown: Before snapshots state, handleEvent: lets
  // AppKit route through the IME (which may call insertText/setMarkedText), and
  // After decides between SendKeyEvent, ImeCommitText, ImeSetComposition,
  // ImeFinishComposingText, ImeCancelComposition based on what the IME did.
  [textInputClient_ HandleKeyEventBeforeTextInputClient:event];
  [textInputContext_ handleEvent:event];
  CefKeyEvent keyEvent;
  FillKeyEventFromNSEvent(keyEvent, event);
  [textInputClient_ HandleKeyEventAfterTextInputClient:keyEvent];
}

- (void)keyUp:(NSEvent*)event {
  if (!browser_.get()) {
    return;
  }
  CefKeyEvent keyEvent;
  FillKeyEventFromNSEvent(keyEvent, event);
  keyEvent.type = KEYEVENT_KEYUP;
  browser_->GetHost()->SendKeyEvent(keyEvent);
}

- (void)flagsChanged:(NSEvent*)event {
  if (!browser_.get()) {
    return;
  }
  CefKeyEvent keyEvent;
  FillKeyEventFromNSEvent(keyEvent, event);
  keyEvent.type = KEYEVENT_RAWKEYDOWN;
  browser_->GetHost()->SendKeyEvent(keyEvent);
}

// Mouse events: we do NOT forward them. The Compose-side pointerInput already
// dispatches synthetic AWT MouseEvents directly to the GLCanvas (which feeds
// CefBrowserOsr's internal MouseListener). If we forwarded native NSEvents up
// here, the responder chain could steal first-responder away from us and
// IME routing would break. Treat this view as a transparent "key event"
// catcher only — let native mouse events fall through Cocoa's hit-testing
// naturally to whichever view is underneath.
- (NSView*)hitTest:(NSPoint)point {
  // Make this view invisible to native mouse hit-testing so clicks pass to
  // siblings/parents underneath. We still get keyDown because we remain
  // first responder.
  return nil;
}

@end

namespace osr_ime_host_mac {

namespace {

// Associated-object key used to attach an OsrImeHostView to the parent
// NSView. Static address — its identity is what matters.
static const char kHostViewAssocKey = 'O';

}  // namespace

void Attach(void* nsWindowPtr,
            void* glCanvasSurfacePtr,
            CefRefPtr<CefBrowser> browser) {
  if (!nsWindowPtr) {
    return;
  }
  // All NSWindow / NSView mutation must happen on the main (AppKit) thread.
  // Java callers typically reach here from the AWT EDT — on JBR that often
  // coincides with the AppKit main thread, but on a standard JDK (e.g. Amazon
  // Corretto) it does not, and AppKit asserts immediately. Hop explicitly.
  void (^body)(void) = ^{
    NSWindow* window = (__bridge NSWindow*)nsWindowPtr;
    NSView* contentView = [window contentView];
    // Idempotent: bail if already attached to this window. We store a weak-ish
    // reference via OBJC_ASSOCIATION_ASSIGN so the host's retain count is owned
    // exclusively by its super view (contentView). Otherwise we'd double-retain
    // and the window's tear-down releases us once via the subview chain and
    // once via the associated object, triggering "over-released" assertion on
    // dealloc.
    OsrImeHostView* existing =
        objc_getAssociatedObject(window, &kHostViewAssocKey);
    if (existing) {
      return;
    }
    OsrImeHostView* host =
        [[OsrImeHostView alloc] initWithBrowser:browser
                                          frame:[contentView bounds]];
    [contentView addSubview:host];
    // ASSIGN, not RETAIN: contentView already strongly retains the subview.
    objc_setAssociatedObject(window, &kHostViewAssocKey, host,
                             OBJC_ASSOCIATION_ASSIGN);
    [window makeFirstResponder:host];
#if !__has_feature(objc_arc)
    // addSubview retained; balance our alloc.
    [host release];
#endif
  };
  if ([NSThread isMainThread]) {
    body();
  } else {
    dispatch_async(dispatch_get_main_queue(), body);
  }
}

void UpdateCompositionRange(void* nsWindowPtr,
                            const CefRange& selected_range,
                            const std::vector<CefRect>& character_bounds) {
  if (!nsWindowPtr) {
    return;
  }
  // Same threading rule as Attach: NSView/NSTextInputClient state must be
  // touched only on the main thread. Capture by value so the block can run
  // later without keeping references to caller-stack data.
  CefRange selected_range_copy = selected_range;
  std::vector<CefRect> character_bounds_copy = character_bounds;
  void (^body)(void) = ^{
    NSWindow* window = (__bridge NSWindow*)nsWindowPtr;
    OsrImeHostView* host =
        objc_getAssociatedObject(window, &kHostViewAssocKey);
    if (!host) {
      return;
    }
    [[host textInputClient] ChangeCompositionRange:selected_range_copy
                                   character_bounds:character_bounds_copy];
  };
  if ([NSThread isMainThread]) {
    body();
  } else {
    dispatch_async(dispatch_get_main_queue(), body);
  }
}

void SetActive(void* nsWindowPtr, bool active) {
  if (!nsWindowPtr) return;
  void (^body)(void) = ^{
    NSWindow* window = (__bridge NSWindow*)nsWindowPtr;
    OsrImeHostView* host =
        objc_getAssociatedObject(window, &kHostViewAssocKey);
    if (!host) return;
    [host setShouldReclaim:active ? YES : NO];
    if (!active && [window firstResponder] == host) {
      // Yield first-responder so AWT's next mouse / key target can claim it.
      [window makeFirstResponder:[window contentView]];
    } else if (active && [window firstResponder] != host) {
      [window makeFirstResponder:host];
    }
  };
  if ([NSThread isMainThread]) body();
  else dispatch_async(dispatch_get_main_queue(), body);
}

}  // namespace osr_ime_host_mac
