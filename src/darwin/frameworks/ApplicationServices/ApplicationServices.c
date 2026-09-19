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

const char* ApplicationServicesVersionString = "Darling ApplicationServices-48";
const unsigned long long ApplicationServicesVersionNumber = 0x4048000000000000;

/*
 * PlotIconRefInContext, in ApplicationServices because that is where the caller looks for it:
 *   (undefined) external _PlotIconRefInContext (from ApplicationServices)
 * while GetIconRef and ReleaseIconRef in the same caller come from CoreServices. Two-level
 * namespace means each has to be defined in the library that is named, not in one place. Task #235.
 *
 * Nothing can be plotted without an icon database, and there is none. paramErr is honest for the
 * only IconRef this port ever hands out, which is NULL.
 */
typedef struct OpaqueIconRef *IconRef;

long PlotIconRefInContext(void *ctx, const void *rect, short align, short transform,
                          const void *labelColor, unsigned int flags, IconRef theIconRef)
{
    return -50 /* paramErr */;
}
