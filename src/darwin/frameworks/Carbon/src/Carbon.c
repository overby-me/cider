/*
 This file is part of Darling.

 Copyright (C) 2017 Lubos Dolezel

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


#include <Carbon/Carbon.h>

#include <stdlib.h>
#include <stdio.h>

static int verbose = 0;

__attribute__((constructor))
static void initme(void) {
    verbose = getenv("STUB_VERBOSE") != NULL;
}


/*
 * HIToolbox: hot keys, theme metrics and theme drawing.
 *
 * NO HEADER IN THIS TREE DECLARES ANY OF THESE, so they are declared here. C linkage is by name,
 * and every parameter below is a pointer or a 32-bit integer, so the declarations agree with the
 * real ABI even though the real types (EventHotKeyID, HIRect, HIThemeMenuDrawInfo) do not exist
 * here. EventHotKeyID is two UInt32 passed by value, which is one integer register, which is what
 * an unsigned long long is.
 *
 * THEY RETURN AN ERROR RATHER THAN SUCCESS, and that is the useful part. A caller that checks
 * takes its own fallback path, which for theme drawing means an application draws its widgets
 * itself instead of getting an empty rectangle from us. Claiming success and doing nothing would
 * produce a window with invisible controls, which is far harder to diagnose than a fallback.
 *
 * LibreOffice reaches RegisterEventHotKey from libAppleRemotelo.dylib during startup, which is
 * how these were found: the missing symbol aborted the process at first call.
 */
enum { cider_unimpErr = -4 };

OSStatus RegisterEventHotKey(UInt32 inHotKeyCode, UInt32 inHotKeyModifiers,
                             unsigned long long inHotKeyID, void *inTarget,
                             UInt32 inOptions, void **outRef)
{
    if (verbose) puts("STUB: RegisterEventHotKey called");
    if (outRef) *outRef = NULL;
    return cider_unimpErr;
}

OSStatus UnregisterEventHotKey(void *inHotKey)
{
    if (verbose) puts("STUB: UnregisterEventHotKey called");
    return cider_unimpErr;
}

/*
 * The metric is zeroed as well as reported failed: a caller that ignores the status still reads a
 * defined value rather than whatever was on its stack.
 */
/* CoreGraphics, declared rather than included: this file has no CG header in its include path and
 * the framework is reexported by this one, so the symbols resolve at link time. */
typedef double CiderCGFloat;
typedef struct CiderCGRect { CiderCGFloat x, y, width, height; } CiderCGRect;
typedef struct CiderCGContext *CiderCGContextRef;
extern void CGContextSaveGState(CiderCGContextRef);
extern void CGContextRestoreGState(CiderCGContextRef);
extern void CGContextSetLineWidth(CiderCGContextRef, CiderCGFloat);
extern void CGContextSetRGBStrokeColor(CiderCGContextRef, CiderCGFloat, CiderCGFloat, CiderCGFloat,
                                       CiderCGFloat);
extern void CGContextStrokeRect(CiderCGContextRef, CiderCGRect);

OSStatus GetThemeMetric(UInt32 inMetric, int *outMetric)
{
    if (getenv("CIDER_TRACE_THEME") != NULL) {
        fprintf(stderr, "CIDER_THEME GetThemeMetric metric=%u\n", (unsigned) inMetric);
    }
    if (verbose) puts("STUB: GetThemeMetric called");
    if (outMetric) *outMetric = 0;
    return cider_unimpErr;
}

/*
 * THE FRAME AROUND A FIELD, which LibreOffice asks for and nothing was drawing.
 *
 * It is one of only four theme calls the application imports (with the two menu ones and the text
 * box), and the stub returned an error so that callers would fall back. For a FRAME there is
 * nothing to fall back to that looks right: the toolbar fields came out as flat white boxes with no
 * edge, which is one of the places the interface stops looking like macOS.
 *
 * HIThemeFrameDrawInfo is version, kind, state, isFocused, in that order, all 32 bit. Only the kind
 * and the focus are used here: a text field and a list box are a hairline rectangle in slightly
 * different greys, and a focused field on Apple systems grows a ring, which is drawn in the system
 * accent blue.
 *
 * DRAWN IN THE CALLER CONTEXT AND STATE-RESTORED, because this is called in the middle of the
 * application own drawing and must not leak a colour or a line width into it.
 */
OSStatus HIThemeDrawFrame(const void *inRect, const void *inDrawInfo, void *inContext,
                          UInt32 inOrientation)
{
    const CiderCGRect *rect = (const CiderCGRect *) inRect;
    const UInt32 *info = (const UInt32 *) inDrawInfo;
    CiderCGContextRef context = (CiderCGContextRef) inContext;

    if (verbose) puts("STUB: HIThemeDrawFrame called");
    if (rect == NULL || context == NULL) {
        return cider_unimpErr;
    }

    const UInt32 kind = (info != NULL) ? info[1] : 0;
    const UInt32 isFocused = (info != NULL) ? info[3] : 0;

    /* kHIThemeFrameListBox is a touch darker than a text field, which is the only difference that
     * survives at this size. */
    const CiderCGFloat grey = (kind == 1) ? 0.62 : 0.70;

    CGContextSaveGState(context);
    CGContextSetLineWidth(context, 1.0);
    CGContextSetRGBStrokeColor(context, grey, grey, grey + 0.02, 1.0);
    CiderCGRect edge = { rect->x + 0.5, rect->y + 0.5, rect->width - 1.0, rect->height - 1.0 };
    CGContextStrokeRect(context, edge);

    if (isFocused) {
        CGContextSetRGBStrokeColor(context, 0.15, 0.45, 0.90, 0.85);
        CGContextSetLineWidth(context, 2.0);
        CiderCGRect ring = { rect->x + 1.0, rect->y + 1.0, rect->width - 2.0, rect->height - 2.0 };
        CGContextStrokeRect(context, ring);
    }
    CGContextRestoreGState(context);
    return 0;
}

OSStatus HIThemeDrawMenuBackground(const void *inMenuRect, const void *inMenuDrawInfo,
                                   void *inContext, UInt32 inOrientation)
{
    if (verbose) puts("STUB: HIThemeDrawMenuBackground called");
    return cider_unimpErr;
}

OSStatus HIThemeDrawMenuItem(const void *inMenuRect, const void *inItemRect,
                             const void *inDrawInfo, void *inContext, UInt32 inOrientation,
                             void *outItemRect)
{
    if (verbose) puts("STUB: HIThemeDrawMenuItem called");
    return cider_unimpErr;
}

OSStatus HIThemeDrawTextBox(const void *inString, const void *inBounds, void *inTextInfo,
                            void *inContext, UInt32 inOrientation)
{
    if (verbose) puts("STUB: HIThemeDrawTextBox called");
    return cider_unimpErr;
}

/*
 * Secure event input is about keystrokes not reaching other processes while a password field has
 * focus. There is one process here and no window server to ask, so reporting success is true
 * rather than optimistic: nothing else can be listening.
 */
OSStatus EnableSecureEventInput(void)
{
    if (verbose) puts("STUB: EnableSecureEventInput called");
    return 0;
}

OSStatus DisableSecureEventInput(void)
{
    if (verbose) puts("STUB: DisableSecureEventInput called");
    return 0;
}

/*
 * ZERO IS THE CORRECT ANSWER, not a placeholder: no buttons are down and no modifiers are held
 * when there is no seat, which is exactly what the Wayland display backend reports for the same
 * question.
 */
UInt32 GetCurrentEventButtonState(void)
{
    if (verbose) puts("STUB: GetCurrentEventButtonState called");
    return 0;
}

UInt32 GetCurrentEventKeyModifiers(void)
{
    if (verbose) puts("STUB: GetCurrentEventKeyModifiers called");
    return 0;
}

// These stubs should prob be moved elsewhere

OSErr ActivateTSMDocument(TSMDocumentID a)
{
    if (verbose) puts("STUB: ActivateTSMDocument called");
	return 0;
}

OSErr DeactivateTSMDocument(TSMDocumentID a)
{
    if (verbose) puts("STUB: DeactivateTSMDocument called");
	return 0;
}

OSStatus CreateStandardAlert(AlertType a, CFStringRef b, CFStringRef c, const AlertStdCFStringAlertParamRec * d, DialogRef * e)
{
    if (verbose) puts("STUB: CreateStandardAlert called");
	return 0;
}

OSErr UseInputWindow(TSMDocumentID a, Boolean b)
{
    if (verbose) puts("STUB: UseInputWindow called");
	return 0;
}

void FlushEvents(EventMask a, EventMask b)
{
    if (verbose) puts("STUB: FlushEvents called");
}

EventTargetRef GetApplicationEventTarget(void)
{
    if (verbose) puts("STUB: GetApplicationEventTarget called");
	return (EventTargetRef)0;
}

OSStatus GetEventDispatcherTarget()
{
    if (verbose) puts("STUB: GetEventDispatcherTarget called");
	return 0;
}

OSStatus GetScrapByName(CFStringRef a, OptionBits b, ScrapRef * c)
{
    if (verbose) puts("STUB: GetScrapByName called");
	return 0;
}

OSStatus GetScrapFlavorData(ScrapRef a, ScrapFlavorType b, Size * c, void * d)
{
    if (verbose) puts("STUB: GetScrapFlavorData called");
	return 0;
}

OSStatus GetScrapFlavorSize(ScrapRef a, ScrapFlavorType b, Size * c)
{
    if (verbose) puts("STUB: GetScrapFlavorSize called");
	return 0;
}

OSStatus GetStandardAlertDefaultParams(AlertStdCFStringAlertParamPtr a, UInt32 b)
{
    if (verbose) puts("STUB: GetStandardAlertDefaultParams called");
	return 0;
}

void HideMenuBar(void)
{
    if (verbose) puts("STUB: HideMenuBar called");
	
}

OSErr NMInstall(NMRecPtr a)
{
    if (verbose) puts("STUB: NMInstall called");
	return 0;
}

OSErr NewTSMDocument(short a, InterfaceTypeList b, TSMDocumentID * c, long d)
{
    if (verbose) puts("STUB: NewTSMDocument called");
	return 0;
}

OSStatus ProcessHICommand(const HICommand * a)
{
    if (verbose) puts("STUB: ProcessHICommand called");
	return 0;
}

OSStatus PutScrapFlavor(ScrapRef a, ScrapFlavorType b, ScrapFlavorFlags c, Size d, const void * e)
{
    if (verbose) puts("STUB: PutScrapFlavor called");
	return 0;
}

void RunApplicationEventLoop(void)
{
    if (verbose) puts("STUB: RunApplicationEventLoop called");
	
}

OSStatus RunStandardAlert(DialogRef a, ModalFilterUPP b, DialogItemIndex * c)
{
    if (verbose) puts("STUB: RunStandardAlert called");
	return 0;
}

OSStatus SetEventMask(EventMask a)
{
    if (verbose) puts("STUB: SetEventMask called");
	return 0;
}

OSStatus SetEventParameter(EventRef a, EventParamName b, EventParamType c, UInt32 d, const void * e)
{
    if (verbose) puts("STUB: SetEventParameter called");
	return 0;
}

void ShowMenuBar(void)
{
    if (verbose) puts("STUB: ShowMenuBar called");
}


void GetKeys (KeyMap theKeys)
{

}

