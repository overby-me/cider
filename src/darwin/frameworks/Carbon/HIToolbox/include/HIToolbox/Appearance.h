/*
 This file is part of Darling.

 Copyright (C) 2025 Darling Developers

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

#ifndef _HITOOLBOX_APPEARANCE_H_
#define _HITOOLBOX_APPEARANCE_H_

#include <CoreServices/CoreServices.h>

// Values captured from macOS. A brush or button kind that is off by one selects the wrong
// drawing entirely rather than failing, so these are transcribed, not inferred.

typedef SInt16 ThemeBrush;
enum {
	kThemeBrushDialogBackgroundActive           = 1,
	kThemeBrushDialogBackgroundInactive         = 2,
	kThemeBrushAlertBackgroundActive            = 3,
	kThemeBrushAlertBackgroundInactive          = 4,
	kThemeBrushModelessDialogBackgroundActive   = 5,
	kThemeBrushModelessDialogBackgroundInactive = 6,
	kThemeBrushUtilityWindowBackgroundActive    = 7,
	kThemeBrushUtilityWindowBackgroundInactive  = 8,
	kThemeBrushListViewSortColumnBackground     = 9,
	kThemeBrushListViewBackground               = 10,
	kThemeBrushIconLabelBackground              = 11,
	kThemeBrushListViewSeparator                = 12,
	kThemeBrushChasingArrows                    = 13,
	kThemeBrushDragHilite                       = 14,
	kThemeBrushDocumentWindowBackground         = 15,
	kThemeBrushFinderWindowBackground           = 16,
	kThemeBrushScrollBarDelimiterActive         = 17,
	kThemeBrushScrollBarDelimiterInactive       = 18,
	kThemeBrushFocusHighlight                   = 19,
	kThemeBrushPopupArrowActive                 = 20,
	kThemeBrushPopupArrowPressed                = 21,
	kThemeBrushPopupArrowInactive               = 22,
	kThemeBrushAppleGuideCoachmark              = 23,
	kThemeBrushIconLabelBackgroundSelected      = 24,
	kThemeBrushStaticAreaFill                   = 25,
	kThemeBrushActiveAreaFill                   = 26,
	kThemeBrushButtonFrameActive                = 27,
	kThemeBrushButtonFrameInactive              = 28,
	kThemeBrushButtonFaceActive                 = 29,
	kThemeBrushButtonFaceInactive               = 30,
	kThemeBrushButtonFacePressed                = 31,
	kThemeBrushButtonActiveDarkShadow           = 32,
	kThemeBrushButtonActiveDarkHighlight        = 33,
	kThemeBrushButtonActiveLightShadow          = 34,
	kThemeBrushButtonActiveLightHighlight       = 35,
	kThemeBrushButtonInactiveDarkShadow         = 36,
	kThemeBrushButtonInactiveDarkHighlight      = 37,
	kThemeBrushButtonInactiveLightShadow        = 38,
	kThemeBrushButtonInactiveLightHighlight     = 39,
	kThemeBrushButtonPressedDarkShadow          = 40,
	kThemeBrushButtonPressedDarkHighlight       = 41,
	kThemeBrushButtonPressedLightShadow         = 42,
	kThemeBrushButtonPressedLightHighlight      = 43,
	kThemeBrushBevelActiveLight                 = 44,
	kThemeBrushBevelActiveDark                  = 45,
	kThemeBrushBevelInactiveLight               = 46,
	kThemeBrushBevelInactiveDark                = 47,
	kThemeBrushNotificationWindowBackground     = 48,
	kThemeBrushMovableModalBackground           = 49,
	kThemeBrushSheetBackgroundOpaque            = 50,
	kThemeBrushDrawerBackground                 = 51,
	kThemeBrushToolbarBackground                = 52,
	kThemeBrushSheetBackgroundTransparent       = 53,
	kThemeBrushMenuBackground                   = 54,
	kThemeBrushMenuBackgroundSelected           = 55,
	kThemeBrushListViewOddRowBackground         = 56,
	kThemeBrushListViewEvenRowBackground        = 57,
	kThemeBrushListViewColumnDivider            = 58,
	kThemeBrushSheetBackground                  = 50,
	kThemeBrushBlack                            = -1,
	kThemeBrushWhite                            = -2,
	kThemeBrushPrimaryHighlightColor            = -3,
	kThemeBrushSecondaryHighlightColor          = -4,
	kThemeBrushAlternatePrimaryHighlightColor   = -5,
};

typedef UInt16 ThemeButtonValue;
enum {
	kThemeButtonOff   = 0,
	kThemeButtonOn    = 1,
	kThemeButtonMixed = 2,
};

typedef UInt16 ThemeDisclosureState;
enum {
	kThemeDisclosureRight = 0,
	kThemeDisclosureDown  = 1,
	kThemeDisclosureLeft  = 2,
};

typedef UInt16 ThemeButtonAdornment;
enum {
	kThemeAdornmentNone                              = 0,
	kThemeAdornmentDefault                           = (1 << 0),
	kThemeAdornmentFocus                             = (1 << 2),
	kThemeAdornmentRightToLeft                       = (1 << 4),
	kThemeAdornmentDrawIndicatorOnly                 = (1 << 5),
	kThemeAdornmentHeaderButtonLeftNeighborSelected  = (1 << 6),
	kThemeAdornmentHeaderButtonRightNeighborSelected = (1 << 7),
	kThemeAdornmentHeaderButtonSortUp                = (1 << 8),
	kThemeAdornmentHeaderMenuButton                  = (1 << 9),
	kThemeAdornmentHeaderButtonNoShadow              = (1 << 10),
	kThemeAdornmentHeaderButtonShadowOnly            = (1 << 11),
	kThemeAdornmentNoShadow                          = (1 << 10),
	kThemeAdornmentShadowOnly                        = (1 << 11),
	kThemeAdornmentArrowLeftArrow                    = (1 << 6),
	kThemeAdornmentArrowDownArrow                    = (1 << 7),
	kThemeAdornmentArrowDoubleArrow                  = (1 << 8),
	kThemeAdornmentArrowUpArrow                      = (1 << 9),
};

typedef UInt16 ThemeButtonKind;
enum {
	kThemePushButton         = 0,
	kThemeCheckBox           = 1,
	kThemeRadioButton        = 2,
	kThemeBevelButton        = 3,
	kThemeArrowButton        = 4,
	kThemePopupButton        = 5,
	kThemeDisclosureButton   = 6,
	kThemeIncDecButton       = 7,
	kThemeSmallBevelButton   = 8,
	kThemeMediumBevelButton  = 3,
	kThemeLargeBevelButton   = 9,
	kThemeListHeaderButton   = 10,
	kThemeRoundButton        = 11,
	kThemeLargeRoundButton   = 12,
	kThemeSmallCheckBox      = 13,
	kThemeSmallRadioButton   = 14,
	kThemeRoundedBevelButton = 15,
	kThemeNormalCheckBox     = 1,
	kThemeNormalRadioButton  = 2,
};


#endif // _HITOOLBOX_APPEARANCE_H_
