/*
 This file is part of Darling.

 Copyright (C) 2019 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

#import <QuickLookUI/QLPreviewPanel.h>

/* THE CLASS WAS EMPTY, AND THAT KILLED ITERM2 ON EVERY WINDOW ACTIVATION.
 *
 * -[PseudoTerminal windowDidBecomeKey:] asks +sharedPreviewPanelExists, which did not exist, so the
 * runtime raised NSInvalidArgumentException. The raise unwound out through
 * wayland_appkit_lib::input::on_keyboard_enter, which is extern C and cannot unwind, and Rust
 * aborted the process. From outside that is a terminal that dies when you give it focus.
 *
 * The two methods are a pair on purpose: asking whether the panel exists must NOT create it, which
 * is the whole reason the application calls the first one. */
static QLPreviewPanel *sSharedPreviewPanel = nil;

@implementation QLPreviewPanel

+ (BOOL) sharedPreviewPanelExists
{
    return sSharedPreviewPanel != nil;
}

+ (QLPreviewPanel *) sharedPreviewPanel
{
    if (sSharedPreviewPanel == nil) {
        sSharedPreviewPanel = [[self alloc]
                initWithContentRect: NSMakeRect(0, 0, 640, 480)
                          styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                     NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
                            backing: NSBackingStoreBuffered
                              defer: YES];
    }

    return sSharedPreviewPanel;
}

@end
