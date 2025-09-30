#include <metal_stdlib>
using namespace metal;
struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
};

struct VertexIn {
  vector_float2 position;
  vector_float2 texcoord;
};

//
// Original version by KroneCorylus, ref https://github.com/KroneCorylus/shader-playground/blob/main/shaders/cursor_smear_fade.glsl
//
// Modifications:
// - Base the cursor trail color on the current cursor color, which can be configured
//   in ghostty's config using `cursor-color`, ref https://ghostty.org/docs/config/reference#cursor-color
// - Cursor trail is partially transparent, which gives a nice fade effect
// - Cursor trail's maximum opacity is configurable using `TRAIL_MAX_OPACITY`
//

// reference hex to float4 color converter:
// https://enchanted.games/app/colour-converter/

// How long the cursor trail duration
// NOTE: It's much easier to debug the shader when you make this value
// much larger, effectively slowing everything down so you can perceive
// subtle trail effects
const constant float DURATION = 0.3; //IN SECONDS

// How opaque should the cursor trail be as it approaches the new cursor
// position, valid range between [0..1]
const constant float TRAIL_MAX_OPACITY = 0.1;


float getSdfRectangle(float2 p, float2 xy, float2 b)
{
    float2 d = abs(p - xy) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Based on Inigo Quilez's 2D distance functions article: https://iquilezles.org/articles/distfunctions2d/
// Potencially optimized by eliminating conditionals and loops to enhance performance and reduce branching

float seg(float2 p, float2 a, float2 b, thread float &s, float d) {
    float2 e = b - a;
    float2 w = p - a;
    float2 proj = a + e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
    float segd = dot(p - proj, p - proj);
    d = min(d, segd);

    float c0 = step(0.0, p.y - a.y);
    float c1 = 1.0 - step(0.0, p.y - b.y);
    float c2 = 1.0 - step(0.0, e.x * w.y - e.y * w.x);
    float allCond = c0 * c1 * c2;
    float noneCond = (1.0 - c0) * (1.0 - c1) * (1.0 - c2);
    float flip = mix(1.0, -1.0, step(0.5, allCond + noneCond));
    s *= flip;
    return d;
}

float getSdfParallelogram(float2 p, float2 v0, float2 v1, float2 v2, float2 v3) {
    float s = 1.0;
    float d = dot(p - v0, p - v0);

    d = seg(p, v0, v3, s, d);
    d = seg(p, v1, v0, s, d);
    d = seg(p, v2, v1, s, d);
    d = seg(p, v3, v2, s, d);

    return s * sqrt(d);
}

float2 normalize_res(float2 value, float isPosition) {
    return (value * 2.0 - (float2(1., 1.) * isPosition));
}

float antialising(float distance) {
    return 1. - smoothstep(0., 0.00001, distance);
}

float determineStartVertexFactor(float2 a, float2 b) {
    // Conditions using step
    float condition1 = step(b.x, a.x) * step(a.y, b.y); // a.x < b.x && a.y > b.y
    float condition2 = step(a.x, b.x) * step(b.y, a.y); // a.x > b.x && a.y < b.y

    // If neither condition is met, return 1 (else case)
    return 1.0 - max(condition1, condition2);
}

float2 getRectangleCenter(float4 rectangle) {
    return float2(rectangle.x + (rectangle.z / 2.), rectangle.y - (rectangle.w / 2.));
}
float ease(float x) {
    return pow(1.0 - x, 3.0);
}

struct FragmentMeta {
    vector_float4 previousCursor;
    vector_float4 currentCursor;
    vector_float4 currentCursorColor;
    float timeDelta;
};

fragment float4 invert_colors_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> input_texture [[texture(0)]],
    constant FragmentMeta* meta [[buffer(0)]]
)
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 color = input_texture.sample(s, in.texcoord);

    // Normalization for fragCoord to a space of -1 to 1;
    float2 vu = in.texcoord * 2.0 - 1.0;
    float2 offsetFactor = float2(-.5, 0.5);

    // Normalization for cursor position and size;
    // cursor xy has the postion in a space of -1 to 1;
    // zw has the width and height
    float4 currentCursor = float4(normalize_res(meta->currentCursor.xy, 1.), normalize_res(meta->currentCursor.zw, 0.));
    float4 previousCursor = float4(normalize_res(meta->previousCursor.xy, 1.), normalize_res(meta->previousCursor.zw, 0.));

    // When drawing a parellelogram between cursors for the trail i need to determine where to start at the top-left or top-right vertex of the cursor
    float vertexFactor = determineStartVertexFactor(currentCursor.xy, previousCursor.xy);
    float invertedVertexFactor = 1.0 - vertexFactor;

    // Set every vertex of my parellogram
    float2 v0 = float2(currentCursor.x + currentCursor.z * vertexFactor, currentCursor.y - currentCursor.w);
    float2 v1 = float2(currentCursor.x + currentCursor.z * invertedVertexFactor, currentCursor.y);
    float2 v2 = float2(previousCursor.x + currentCursor.z * invertedVertexFactor, previousCursor.y);
    float2 v3 = float2(previousCursor.x + currentCursor.z * vertexFactor, previousCursor.y - previousCursor.w);

    float sdfCurrentCursor = getSdfRectangle(vu, currentCursor.xy - (currentCursor.zw * offsetFactor), currentCursor.zw * 0.5);
    float sdfTrail = getSdfParallelogram(vu, v0, v1, v2, v3);

    float progress = clamp(meta->timeDelta / DURATION, 0.0, 1.0);
    float easedProgress = ease(progress);
    // Distance between cursors determine the total length of the parallelogram;
    float2 centerCC = getRectangleCenter(currentCursor);
    float2 centerCP = getRectangleCenter(previousCursor);
    float lineLength = distance(centerCC, centerCP);

    // Compute fade factor based on distance along the trail
    float fadeFactor = clamp(1.0 - smoothstep(lineLength, sdfCurrentCursor, easedProgress * lineLength), 0., TRAIL_MAX_OPACITY);

    // Apply fading effect to trail color
    float4 fadedTrailColor = mix(color, meta->currentCursorColor, fadeFactor);

    // Blend trail with fade effect
    float4 newColor =  mix(color, fadedTrailColor, antialising(sdfTrail));

    // Draw current cursor
    newColor = mix(newColor, meta->currentCursorColor , antialising(sdfCurrentCursor));
    newColor = mix(newColor, color, step(sdfCurrentCursor, 0.));
    color = mix(color, newColor, step(sdfCurrentCursor, easedProgress * lineLength));

    return color;
}
vertex VertexOut simple_vertex(
    uint vid [[vertex_id]],
    constant VertexIn* vertices [[buffer(0)]],
    constant vector_uint2 *viewportSizePtr [[buffer(1)]])
{
    VertexOut out;
    float2 pixelSpacePosition = vertices[vid].position.xy;
    float2 viewportSize = float2(*viewportSizePtr);
    out.position = vector_float4(0.0, 0.0, 0.0, 1.0);
    out.position.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.texcoord = vertices[vid].texcoord;
    return out;
}
