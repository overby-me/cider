/*
 * Combine, far enough that an application which links it can be LOADED.
 *
 * Combine is a Swift framework: publishers, subscribers and the operators between them. Almost
 * nothing in it is reachable from Objective-C, and none of it is implemented here. What this file
 * is for is the load: a hard link to a framework that does not exist stops dyld before the process
 * runs a single instruction, and the Swift compiler emits that link into any binary where a Combine
 * type is so much as mentioned. iA Writer is one of those.
 *
 * So this exists to answer the question HOW MUCH of Combine an application actually reaches, which
 * cannot be measured while the loader refuses to start it. If the answer turns out to be nothing,
 * the framework is done. If it is a list of Swift symbols, that list is the work, and it will be
 * written down rather than guessed at.
 */

#import <Foundation/Foundation.h>

/*
 * The version symbol every framework carries. It is here so the dylib has at least one export and
 * so a caller that reads the version gets a truthful zero rather than a missing symbol.
 */
const double CombineVersionNumber = 0.0;
const unsigned char CombineVersionString[] = "Combine 0.0 (Cider stub)";
