// cider #11 lever A: stub the dyld3::json readers so the cache builder links without JSONReader.mm,
// which drags in <Foundation/Foundation.h> + NSJSONSerialization. JSON input is only consumed for
// ObjC-optimization order files, which this builder never adds, so these are never called at runtime.
#include "JSON.h"
#include "JSONReader.h"
#include "Diagnostics.h"

namespace dyld3 {
namespace json {

Node readJSON(Diagnostics& diags, const char* filePath) {
    diags.error("cider cache builder: JSON reading is not supported");
    return Node();
}

Node readJSON(Diagnostics& diags, const void* contents, size_t length) {
    diags.error("cider cache builder: JSON reading is not supported");
    return Node();
}

const Node& getRequiredValue(Diagnostics& diags, const Node& node, const char* key) {
    static Node empty;
    diags.error("cider cache builder: json getRequiredValue is not supported");
    return empty;
}

const Node* getOptionalValue(Diagnostics& diags, const Node& node, const char* key) {
    return nullptr;
}

uint64_t parseRequiredInt(Diagnostics& diags, const Node& node) {
    diags.error("cider cache builder: json parseRequiredInt is not supported");
    return 0;
}

bool parseRequiredBool(Diagnostics& diags, const Node& node) {
    diags.error("cider cache builder: json parseRequiredBool is not supported");
    return false;
}

const std::string& parseRequiredString(Diagnostics& diags, const Node& node) {
    static std::string empty;
    diags.error("cider cache builder: json parseRequiredString is not supported");
    return empty;
}

} // namespace json
} // namespace dyld3
