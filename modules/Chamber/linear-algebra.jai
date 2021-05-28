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

mat4 :: Matrix4;

// Following GLM naming.
quat :: Quaternion;

/*
    A 3D transform, stored as TRS.

    Rationale is that, sometimes, we don't want to use mat4 directly
    if this is just for affine transforms.

    @note Non-uniform scaling is not allowed:
        this representation would fail for
        inverses or compositions (both might add shear).
*/
trs :: struct {
    translation : vec3;
    rotation : quat;
    scaling : float = 1.;
}

make_mat4 :: (transform : trs) -> mat4 {
    matrix : mat4 = ---;
    matrix = make_rotation_matrix4(transform.rotation);
    matrix *= make_scaling_mat4(transform.scaling);
    matrix.coef[0][3] = transform.translation.x;
    matrix.coef[1][3] = transform.translation.y;
    matrix.coef[2][3] = transform.translation.z;
    return matrix;
}

to_radians :: (degrees : float32) -> float32 {
    return degrees * #run cast(float32) (PI / 180.);
}

make_scaling_mat4 :: (scaling : float32) -> mat4 {
    matrix : mat4 = ---;
    matrix = inline matrix4_identity();
    matrix.coef[0][0] = scaling;
    matrix.coef[1][1] = scaling;
    matrix.coef[2][2] = scaling;
    return matrix;
}

/*
    This matrix input is supposed right-handed convention, looking towards +Z and down is +Y.
    Which means that you usually want to pass your geometry through a "look_at" matrix first.
    The generated normalized device coordinates (NDC) will be
    near-top-left (-1, -1, 1) and far-bottom-right (1, 1, 0).

    That's right, this matrix near and far are inverted. Near being 1 and far being 0.
    This is for precision when things are closed to the eye.
    NVidia had an article about that but that link does not seem to work anymore:
    https://developer.nvidia.com/content/depth-precision-visualized

    - fovX is the field of view (angle, in radians) for the horizontal axis, humans have 210°, but we usually set it to 100° for games.
      Once again, be sure to pass radians here!
      @note Don't know why people like fovY more, I don't.
    - aspectRatio is width/height of the near plane you want (you know, 16:9 and stuff).
    - nearClip is the distance of the near plane, everything between the camera and that distance is clipped.
    - farClip is considered infinite.

    Matrix construction is inspired by http://www.alexisbreust.fr/2018-game-engine-frustum-culling.html ;)
*/
infinite_perspective_projection_matrix :: (fovX : float32, aspectRatio : float32, nearClip : float) -> mat4 {
    matrix : mat4;
    infinite_perspective_projection(*matrix, fovX, aspectRatio, nearClip, false);
    return matrix;
}

infinite_perspective_projection :: (matrix : *mat4, fovX : float32, aspectRatio : float32, nearClip : float, $clear := true) {
    #if clear {
        <<matrix = mat4.{};
    }

    oneOverTanFovXOver2 := 1. / tan(fovX * 0.5);

    matrix.coef[0][0] = oneOverTanFovXOver2;
    matrix.coef[1][1] = aspectRatio * oneOverTanFovXOver2;
    matrix.coef[2][3] = nearClip;
    matrix.coef[3][2] = 1.;
}

/*
    Get the rotation matrix translated to provided origin
    so that X (forward) becomes the looking direction
    from origin to target.
*/
orientation_matrix :: (origin : vec3, target : vec3, reference_up := vec3.{0, 0, 1}) -> mat4 {
    matrix : mat4;
    matrix.coef[3][3] = 1;

    forward : vec3;
    forward.std = target - origin;
    normalize(*forward);

    left : vec3;
    left.std = cross_product(reference_up, forward);
    normalize(*left);

    up : vec3;
    up.std = cross_product(forward.std, left);
    normalize(*up);

    matrix = make_matrix_from_columns(forward.std, left.std, up);
    matrix.coef[0][3] = origin.x;
    matrix.coef[1][3] = origin.y;
    matrix.coef[2][3] = origin.z;

    return matrix;
}

/*
    Look-at matrices are confusing because they combine three things:
        - Orient to look at a certain direction, combined with a translation.
        - Inverse that orientation matrix because you want to use the look-at matrix to move other
            objects into its coordinates system.
        - Adapt your in-engine coordinate system to the one expected by the projection matrix,
            which itself expects to generate according to graphic API NDCs.

    For the last point, we follow Vulkan's conventions:
        - +Z is forward (equivalent to our +X)
        - +Y is down (equivalent to our -Z)
        - +X is left (equivalent to our -Y)
    Which makes it a right-handed system, like ours.
*/
look_at_matrix :: (origin : vec3, target : vec3, reference_up := vec3.{0, 0, 1}) -> mat4 {
    matrix := orientation_matrix(origin, target, reference_up);

    // Eyes transform what they see to there coordinate system,
    // thus it's its inverse that we want.
    matrix = inverse(matrix);

    // As described, we follow Vulkan's coordinate system.
    // Thus X -> Z ; Y -> -X ; Z -> -Y
    TO_VULKAN_COORDS_MATRIX :: Matrix4.{
        0, -1,  0,  0,
        0,  0, -1,  0,
        1,  0,  0,  0,
        0,  0,  0,  1,
    };
    matrix = multiply(TO_VULKAN_COORDS_MATRIX, matrix);

    return matrix;
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

#scope_file

#import "Math";

_vec2 :: struct(T : Type) {
    #if T == float32 {
        union {
            using std : Vector2;
        }
    } else {
        x, y : T;
        #place x;
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
    #if T == float32 {
        union {
            using std : Vector3;
        }
    } else {
        x, y, z : T;
        #place x;
            std : void = ---;
    }

    #place std;
        r, g, b : T = ---;
    #place std;
        s, t, p : T = ---;
    #place std;
        width, height, depth : T = ---;
}

_vec4 :: struct(T : Type) {
    #if T == float32 {
        union {
            using std : Vector4;
        }
    } else {
        x, y, z, w : T;
        #place x;
            std : void = ---;
    }

    #place std;
        r, g, b, a : T = ---;
    #place std;
        s, t, p, q : T = ---;
}
