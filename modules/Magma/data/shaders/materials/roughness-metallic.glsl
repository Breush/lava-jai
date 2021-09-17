#version 450

/**
 * Roughness-metallic material.
 * Based on https://github.com/KhronosGroup/glTF-WebGL-PBR
 * @todo Update it to follow https://github.com/KhronosGroup/glTF-Sample-Viewer/blob/master/source/Renderer/shaders/
 */

// ------------------
// ----- VERTEX -----

#if defined(VERTEX)

#include "../default.vert"

// --------------------
// ----- FRAGMENT -----

#elif defined(FRAGMENT)

#include "../default-header.frag"
#include "../constants.glsl"

// @todo glTF provides more uniforms:
// vec4 albedoColor = vec4(1, 1, 1, 1);
// float roughnessFactor = 1;
// float metallicFactor = 1;

// @todo Don't we prefer to recompile the shader without a certain map if it does not exists?
layout(std140, set = MATERIAL_DESCRIPTOR_SET_INDEX, binding = 0) uniform MaterialShaderObject {
    // @note By default, maps will be 1x1 fully white, so for some,
    // we don't care if it is enabled or not.
    bool normalMapEnabled;      // Normal will default to (0, 0, 1)
    bool emissiveMapEnabled;    // Emissive will default to (0, 0, 0)
} material;

layout(set = MATERIAL_DESCRIPTOR_SET_INDEX, binding = 1) uniform sampler2D normalMap;
layout(set = MATERIAL_DESCRIPTOR_SET_INDEX, binding = 2) uniform sampler2D occlusionMap; // Red channel.
layout(set = MATERIAL_DESCRIPTOR_SET_INDEX, binding = 3) uniform sampler2D emissiveMap;

layout(set = MATERIAL_DESCRIPTOR_SET_INDEX, binding = 4) uniform sampler2D albedoMap;
layout(set = MATERIAL_DESCRIPTOR_SET_INDEX, binding = 5) uniform sampler2D roughnessMetallicMap; // Green and blue channels.

struct Pbr {
    float roughness;        // Material roughness squared.
    float metallic;         // Material metallic.
    vec3 n;                 // Normal vector.
    vec3 v;                 // View vector, from eye to fragment.
    float n_l;              // Absolute angle (cosine) between normal and light vector.
    float n_v;              // Absolute angle (cosine) between normal and view vector.
    float n_h;              // Absolute angle (cosine) between normal and half vector.
    float v_h;              // Absolute angle (cosine) between view and half vector.
    vec3 reflectance0;      // Full reflectance color (normal incidence angle).
    vec3 reflectance90;     // Reflectance color at grazing angle.
    vec3 diffuseColor;      // Color factor for diffuse lighting.
    vec3 specularColor;     // Color factor for specular lighting.
};

/**
 * Basic Lambertian diffuse.
 * From https://archive.org/details/lambertsphotome00lambgoog.
 */
vec3 diffuse(vec3 diffuseColor) {
    return diffuseColor / PI;
}

/**
 * The Fresnel reflectance term.
 * From https://www.cs.virginia.edu/~jdl/bib/appearance/analytic%20models/schlick94b.pdf (Eq. 15).
 */
vec3 specularReflection(Pbr pbr) {
    return pbr.reflectance0 + (pbr.reflectance90 - pbr.reflectance0) * pow(1.0 - pbr.v_h, 5.0);
}

/**
 * Smith Joint GGX
 * Note: Vis = G / (4 * NdotL * NdotV)
 *
 * The specular geometric attenuation,
 * where rougher material will reflect less light back to the viewer.
 * From http://blog.selfshadow.com/publications/s2013-shading-course/karis/s2013_pbs_epic_notes_v2.pdf
 * with alphaRoughness from http://blog.selfshadow.com/publications/s2012-shading-course/burley/s2012_pbs_disney_brdf_notes_v3.pdf.
 * See Eric Heitz. 2014. Understanding the Masking-Shadowing Function in Microfacet-Based BRDFs. Journal of Computer Graphics Techniques.
 */
float visibilityOcclusion(Pbr pbr) {
    float n_l = pbr.n_l;
    float n_v = pbr.n_v;
    float r2 = pbr.roughness;

    float GGXV = n_l * sqrt(n_v * n_v * (1.0 - r2) + r2);
    float GGXL = n_v * sqrt(n_l * n_l * (1.0 - r2) + r2);

    float GGX = GGXV + GGXL;
    if (GGX > 0.0)
    {
        return 0.5 / GGX;
    }
    return 0.0;
}

/**
 * The distribution of microfacet normals across the area being drawn.
 * From "Average Irregularity Representation of a Roughened Surface for Ray Reflection" by T. S. Trowbridge, and K. P. Reitz
 * and the distribution from http://blog.selfshadow.com/publications/s2013-shading-course/karis/s2013_pbs_epic_notes_v2.pdf (Eq. 3).
 */
float microfacetDistribution(Pbr pbr) {
    float f = (pbr.roughness - 1.0) * pbr.n_h * pbr.n_h + 1.0;
    return pbr.roughness / (PI * f * f);
}

/**
 * Contribution for a single light.
 */
vec3 lightContribution(vec3 position, Pbr pbr, vec3 l) {
    // ----- Pre-computing

    vec3 h = normalize(l + pbr.v);
    pbr.n_l = clamp(abs(dot(pbr.n, l)), 0.001, 1.0);
    pbr.n_h = clamp(abs(dot(pbr.n, h)), 0.0, 1.0);
    pbr.v_h = clamp(dot(pbr.v, h), 0.0, 1.0);

    // @todo Have light uniforms for color and energy.
    vec3 lightColor = vec3(1);
    float lightIntensity = 0.8;
    float lightEnergy = lightIntensity * pbr.n_l;

    // ----- BRDF

    // Calculate the shading terms for the microfacet specular shading model
    vec3 F = specularReflection(pbr);
    float Vis = visibilityOcclusion(pbr);
    float D = microfacetDistribution(pbr);

    // Reflectance (BRDF) scaled by the energy of the light.
    vec3 diffuseContrib = (1.0 - F) * diffuse(pbr.diffuseColor);
    vec3 specularContrib = F * Vis * D;

    return lightEnergy * lightColor * (diffuseContrib + specularContrib);
}

void main() {
    setupEye();

    vec3 albedo = texture(albedoMap, uv).rgb;
    float occlusion = texture(occlusionMap, uv).r;
    float roughness = texture(roughnessMetallicMap, uv).g;
    float metallic = texture(roughnessMetallicMap, uv).b;

    vec3 normal = vec3(0, 0, 1);
    if (material.normalMapEnabled) {
        normal = 2 * texture(normalMap, uv).rgb - 1;
    }

    vec3 emissive = vec3(0);
    if (material.emissiveMapEnabled) {
        emissive = texture(emissiveMap, uv).rgb;
    }

    // @todo Make lights be configurable (and share with phong)
    vec3 ls[] = { vec3(-1, -0.2, 0.1), vec3(-1, 1, 0.1), vec3(0.5, 0, -1) };

    // ----- Common variables

    Pbr pbr;
    pbr.n = normalize(tbn * normal);
    pbr.v = normalize(eye.position - position.xyz);
    pbr.n_v = clamp(abs(dot(pbr.n, pbr.v)), 0.001, 1.0);
    // @note Convert to material roughness by squaring the perceptual roughness.
    pbr.roughness = roughness * roughness * roughness * roughness;

    // ----- Diffuse

    const vec3 f0 = vec3(0.04);
    pbr.diffuseColor = albedo * (1.0 - f0);
    pbr.diffuseColor *= (1.0 - metallic);

    // ----- Specular

    pbr.specularColor = mix(f0, albedo, metallic);

    // ----- Reflectance

    // For typical incident reflectance range (between 2% to 100%),
    // set the grazing reflectance to 100% for typical fresnel effect.
    // For very low reflectance range on highly diffuse objects (below 2%),
    // incrementally reduce grazing reflecance to 0%.
    float reflectance = max(max(pbr.specularColor.r, pbr.specularColor.g), pbr.specularColor.b);
    float reflectance90 = clamp(reflectance * 50.0, 0.0, 1.0);
    pbr.reflectance0 = pbr.specularColor;
    pbr.reflectance90 = vec3(reflectance90);

    // ----- Lights contribution

    vec3 color = vec3(0);

    for (int i = 0; i < 3; ++i) {
        vec3 l = normalize(ls[i]);
        vec3 lightContributionColor = lightContribution(position.xyz, pbr, l);
        color += lightContributionColor;
    }

    // ----- Environment contribution

    // @todo
    // color += environmentContribution(pbr);

    // ----- Occlusion

    color *= occlusion;

    // ----- Shadow

    // @todo
    // color *= (1.0 - shadow);

    // ----- Emissive

    color += emissive;

    outColor = vec4(color, 1);
}

#endif
