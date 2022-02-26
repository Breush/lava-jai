#version 450

// @note Currently unused.
// No-op post-processing.

// ------------------
// ----- VERTEX -----

#if defined(VERTEX)

#include "$/post-process-renderer/default.vert"

// --------------------
// ----- FRAGMENT -----

#elif defined(FRAGMENT)

#include "$/post-process-renderer/default-header.frag"

void main() {
    outColor = texture(source, uv);
}

#endif
