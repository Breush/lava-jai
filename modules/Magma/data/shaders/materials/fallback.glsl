#version 450

// ------------------
// ----- VERTEX -----

#if defined(VERTEX)

#include "../default.vert"

// --------------------
// ----- FRAGMENT -----

#elif defined(FRAGMENT)

#include "../default-header.frag"

void main() {
    setupEye();

    // @note This is a basic Phong lighting on white surface.

    /*
        n = normal direction of the fragment
        v = view direction from the eye to the fragment
        l = light direction from the light origin to the fragment
        r = light reflected direction if surface was a perfect mirror,
            from the fragment to the outside
    */
    vec3 n = tbn * vec3(0, 0, 1);
    vec3 v = normalize(position.xyz - eye.position);
    // @todo Make lights be configurable
    vec3 ls[] = { vec3(-1, -0.2, 0.1), vec3(-1, 1, 0.1), vec3(0.5, 0, -1) };

    // Light-specific
    vec3 lightDiffuseColor = vec3(0.95);
    vec3 lightSpecularColor = vec3(0.8);
    float lightIntensity = 1;
    float id = 1;
    float is = 0.2;

    // Material-specific
    float kd = 0.8;
    float ks = 0.5;
    float alpha = 16;

    vec3 diffuse = vec3(0);
    vec3 specular = vec3(0);

    // @todo We could centralize these functions, and do the same with PBR.

    for (int i = 0; i < 3; ++i) {
        vec3 l = normalize(ls[i]);

        float n_l = dot(n, l);
        if (n_l < 0) {
            // Diffuse
            diffuse += lightIntensity * id * -n_l * lightDiffuseColor;

            // Specular
            vec3 r = l - 2 * n_l * n;
            float r_v = dot(r, v);
            if (r_v < 0) {
                specular += lightIntensity * is * pow(-r_v, alpha) * lightSpecularColor;
            }
        }
    }

    vec3 color = max(vec3(0.01), kd * diffuse + ks * specular);
    outColor = vec4(color, 1.0);

    // :FragDepthNeeded
    gl_FragDepth = position.w;
}

#endif
