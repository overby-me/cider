/*
 * THE CONSTANTS A LOCATION CLIENT LINKS, with the values macOS documents.
 *
 * The accuracies are metres and they are compared numerically by every caller, so the numbers are
 * the documented ones rather than round figures. There is no location service behind this framework;
 * the constants exist because the symbols stop a modern application at load time.
 */

#import <Foundation/Foundation.h>

NSString *const kCLErrorDomain = @"kCLErrorDomain";

const double kCLLocationAccuracyBest = -1.0;
const double kCLLocationAccuracyBestForNavigation = -2.0;
const double kCLLocationAccuracyNearestTenMeters = 10.0;
const double kCLLocationAccuracyHundredMeters = 100.0;
const double kCLLocationAccuracyKilometer = 1000.0;
const double kCLLocationAccuracyThreeKilometers = 3000.0;
