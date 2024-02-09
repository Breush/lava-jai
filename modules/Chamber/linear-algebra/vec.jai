#scope_module

vec2 :: _vec2(float32);
svec2 :: _vec2(s32);
uvec2 :: _vec2(u32);

vec3 :: _vec3(float32);
svec3 :: _vec3(s32);
uvec3 :: _vec3(u32);

vec4 :: _vec4(float32);
svec4 :: _vec4(s32);
uvec4 :: _vec4(u32);

Axis :: enum {
    PositiveX;
    PositiveY;
    PositiveZ;
    NegativeX;
    NegativeY;
    NegativeZ;
}

vec2Interface :: struct {
    x, y : float32;
}

vec3Interface :: struct {
    x, y, z : float32;
}

make_vec3 :: (v : $T/interface vec2Interface, z : float32) -> vec3 {
    result : vec3 = ---;
    result.xy = v;
    result.z = z;
    return result;
}

make_vec4 :: (v : $T/interface vec3Interface, w : float32) -> vec4 {
    result : vec4 = ---;
    result.xyz = v;
    result.w = w;
    return result;
}

make_vec4 :: (v : $T/interface vec2Interface, z : float32, w : float32) -> vec4 {
    result : vec4 = ---;
    result.xy = v;
    result.z = z;
    result.w = w;
    return result;
}

operator+ :: (v1 : vec3, v2 : vec3) -> vec3 {
    value : vec3 = ---;
    value.std = v1.std + v2.std;
    return value;
}

operator* :: (v : vec3, factor : float32) -> vec3 #symmetric {
    value : vec3 = ---;
    value.std = v.std * factor;
    return value;
}

round :: (v : *vec2) {
    v.x = Math.floor(v.x + 0.5);
    v.y = Math.floor(v.y + 0.5);
}

// Rotate around the Z (0, 0, 1) axis.
rotate_z :: (v : vec3, angle : float32) -> vec3 {
    cosAngle := cos(angle);
    sinAngle := sin(angle);

    result : vec3 = ---;
    result.x = v.x * cosAngle - v.y * sinAngle;
    result.y = v.x * sinAngle + v.y * cosAngle;
    result.z = v.z;
    return result;
}

// Rotate around an axis.
// axis should be normalized.
rotate :: (v : vec3, angle : float32, axis : vec3) -> vec3 {
    // @note Cheated this from https://en.wikipedia.org/wiki/Rotation_matrix#Rotation_matrix_from_axis_and_angle
    // which states that R_u(theta) * x = u * dot(u, x) + cos(theta) * cross(cross(u, x), u) + sin(theta) * cross(u, x)

    cosAngle := cos(angle);
    sinAngle := sin(angle);
    dotAxisV := dot(axis.std, v.std);
    crossAxisV := cross_product(axis.std, v.std);
    crossCrossAxisVAxis := cross_product(crossAxisV, axis.std);

    result : vec3 = ---;
    result.std = dotAxisV * axis.std + cosAngle * crossCrossAxisVAxis + sinAngle * crossAxisV;
    return result;
}

// Given an origin/target, returns the delta to be applied to the origin to rotate around the target.
rotate_around_target :: (origin : vec3, target : vec3,
                         longitudeAngle : float32, latitudeAngle : float32, $upAxis := Axis.PositiveZ) -> vec3 {
    delta : vec3;
    relativePosition : vec3;
    relativePosition.std = origin - target;

    #if upAxis == .PositiveZ {
        // Nothing to do.
    } else #if upAxis == .NegativeY {
        tmp := relativePosition.z;
        relativePosition.z = relativePosition.y;
        relativePosition.y = tmp;
    } else {
        #assert(false);
    }

    if longitudeAngle < -0.001 || longitudeAngle > 0.001 {
        longitudeDelta := rotate_z(relativePosition, longitudeAngle) - relativePosition;
        delta.std += longitudeDelta;
    }

    if latitudeAngle < -0.001 || latitudeAngle > 0.001 {
        currentLatitudeAngle := asin(relativePosition.z / length(relativePosition));
        if (currentLatitudeAngle + latitudeAngle > PI / 2. - 0.01) {
            latitudeAngle = PI / 2. - 0.01 - currentLatitudeAngle;
        }
        else if (currentLatitudeAngle + latitudeAngle < -PI / 2. + 0.01) {
            latitudeAngle = -PI / 2. + 0.01 - currentLatitudeAngle;
        }

        axis : vec3 = ---;
        axis.x = relativePosition.y;
        axis.y = -relativePosition.x;
        axis.z = 0;
        normalize(*axis.std);

        latitudeDelta := rotate(relativePosition, latitudeAngle, axis) - relativePosition;
        delta.std += latitudeDelta;
    }

    #if upAxis == .NegativeY {
        tmp = delta.z;
        delta.z = delta.y;
        delta.y = tmp;
    }

    return delta;
}

#scope_file

#import "Math";

_vec2 :: struct(T : Type) {
    x, y : T;

    #place x;
    #if T == float32 {
        #as std : Vector2 = ---;
    } else {
        std : void = ---;
    }

    #place x;
        r, g : T = ---;
    #place x;
        s, t : T = ---;
    #place x;
        width, height : T = ---;
}

_vec3 :: struct(T : Type) {
    x, y, z : T;

    #place x;
        #as xy : _vec2(T) = ---;

    #place x;
    #if T == float32 {
        #as std : Vector3 = ---;
    } else {
        std : void = ---;
    }

    #place x;
        r, g, b : T = ---;
    #place x;
        s, t, p : T = ---;
    #place x;
        width, height, depth : T = ---;
}

_vec4 :: struct(T : Type) {
    x, y, z, w : T;

    #place x;
        #as xy : _vec2(T) = ---;

    #place x;
        #as xyz : _vec3(T) = ---;

    #place x;
    #if T == float32 {
        #as std : Vector4 = ---;
    } else {
        std : void = ---;
    }

    #place std;
        r, g, b, a : T = ---;
    #place std;
        s, t, p, q : T = ---;
}
