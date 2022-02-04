// Freely inspired by shader toy https://www.shadertoy.com/view/lt3GRj

vec2 _debugScreenCoords;
vec2 _debugOriginCoords;
vec2 _debugCurrentCoords;
float _debugColor = 1.0;

const vec2 _debugFontSize = vec2(4,5) * vec2(5,3);
const float _debugVerticalMargin = 2.0;

float _debug_digit_bin(const in int x) {
    return x==0?480599.0:x==1?139810.0:x==2?476951.0:x==3?476999.0:x==4?350020.0:x==5?464711.0:x==6?464727.0:x==7?476228.0:x==8?481111.0:x==9?481095.0:0.0;
}

float _debug_value(float value, float digits, float decimals) {
    vec2 charCoord = (_debugScreenCoords - _debugCurrentCoords) / _debugFontSize;
    charCoord.y = - charCoord.y;
    if(charCoord.y < 0.0 || charCoord.y >= 1.0) return 0.0;
    float bits = 0.0;
    float digitIndex1 = digits - floor(charCoord.x) + 1.0;
    if(- digitIndex1 <= decimals) {
        float pow1 = pow(10.0, digitIndex1);
        float absValue = abs(value);
        float pivot = max(absValue, 1.5) * 10.0;
        if(pivot < pow1) {
            if(value < 0.0 && pivot >= pow1 * 0.1) bits = 1792.0;
        } else if(digitIndex1 == 0.0) {
            if(decimals > 0.0) bits = 2.0;
        } else {
            value = digitIndex1 < 0.0 ? fract(absValue) : absValue * 10.0;
            bits = _debug_digit_bin(int (mod(value / pow1, 10.0)));
        }
    }
    return floor(mod(bits / pow(2.0, floor(fract(charCoord.x) * 4.0) + floor(charCoord.y * 5.0) * 4.0), 2.0));
}

void debug_int(float value) {
    int digits = int(log(value) / log(10) + 1.0);
    _debugColor *= 1.0 - _debug_value(value, -1, 0); // @todo It's a bit messy this notion of "digits" here.

    _debugCurrentCoords.x += digits * _debugFontSize.x;
}
void debug_newline() {
    _debugCurrentCoords.x = _debugOriginCoords.x;
    _debugCurrentCoords.y += _debugFontSize.y + _debugVerticalMargin;
}

// @todo Have an "anchor" notion
void debug_set_screen_and_origin_coords(vec2 screenCoords, vec2 originCoords) {
    _debugScreenCoords = screenCoords;
    _debugOriginCoords = originCoords;
    _debugCurrentCoords = originCoords;
}

// Black for printed digits, white for background
vec3 debug_get_color() {
    return vec3(_debugColor);
}
