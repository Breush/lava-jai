#version 450

// @note Currently unused.
// No-op post-processing.

// ------------------
// ----- VERTEX -----

#if defined(VERTEX)

#include "../default.vert"

// --------------------
// ----- FRAGMENT -----

#elif defined(FRAGMENT)

#include "../default-header.frag"

void main() {
    outColor = texture(source, uv);
}

#endif
