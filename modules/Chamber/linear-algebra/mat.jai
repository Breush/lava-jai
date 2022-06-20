// Side-note, contrary to GLSL, we are row-major. So 3x4 means 3 rows and 4 columns.
mat3 :: Matrix3;
mat4 :: Matrix4;
mat3x4 :: Matrix4x3;

/*
    A 3D transform, stored as TRS.

    Rationale is that, sometimes, we don't want to use mat4 directly
    if this is just for affine transforms.
*/
trs :: struct {
    translation : vec3;
    rotation : quat;
    scaling : vec3 = .{1, 1, 1};
}

make_matrix :: (transform : trs, $T := mat3x4) -> T {
    matrix : T = ---;
    tmpMatrix := rotation_matrix(mat3, transform.rotation);
    tmpMatrix *= make_scaling_mat3(transform.scaling);

    copy(*matrix, tmpMatrix);
    matrix.coef[0][3] = transform.translation.x;
    matrix.coef[1][3] = transform.translation.y;
    matrix.coef[2][3] = transform.translation.z;

    #assert T == mat4 || T == mat3x4;
    #if T == mat4 {
        matrix.coef[3][0] = 0;
        matrix.coef[3][1] = 0;
        matrix.coef[3][2] = 0;
        matrix.coef[3][3] = 1;
    }

    return matrix;
}

// Decompose as TRS as long as there is no shear/skew.
make_trs :: (matrix : $T/interface AnyMatrix4x3) -> trs {
    transform : trs;

    transform.translation.x = matrix.coef[0][3];
    transform.translation.y = matrix.coef[1][3];
    transform.translation.z = matrix.coef[2][3];

    transform.scaling.x = sqrt(matrix.coef[0][0] * matrix.coef[0][0] + matrix.coef[0][1] * matrix.coef[0][1] + matrix.coef[0][2] * matrix.coef[0][2]);
    transform.scaling.y = sqrt(matrix.coef[1][0] * matrix.coef[1][0] + matrix.coef[1][1] * matrix.coef[1][1] + matrix.coef[1][2] * matrix.coef[1][2]);
    transform.scaling.z = sqrt(matrix.coef[2][0] * matrix.coef[2][0] + matrix.coef[2][1] * matrix.coef[2][1] + matrix.coef[2][2] * matrix.coef[2][2]);

    transform.rotation = get_rotation(matrix);

    return transform;
}

multiply :: (transform : trs, v : $T/interface vec3Interface) -> vec3 {
    result : vec3;
    result.std = transform.translation + rotate(transform.scaling * v, transform.rotation);
    return result;
}

/*
    A TRS but with scaling being uniform.
    This allows for inverses and compositions
    within the same data structure.
    (With non-uniform scaling, shear might happen.)
*/
trf :: struct {
    translation : vec3;
    rotation : quat;
    factor : float = 1.;
}

make_matrix :: (transform : trf, $T := mat3x4) -> T {
    matrix : T = ---;
    tmpMatrix := rotation_matrix(mat3, transform.rotation);
    tmpMatrix *= make_scaling_mat3(transform.factor);

    copy(*matrix, tmpMatrix);
    matrix.coef[0][3] = transform.translation.x;
    matrix.coef[1][3] = transform.translation.y;
    matrix.coef[2][3] = transform.translation.z;

    #assert T == mat4 || T == mat3x4;
    #if T == mat4 {
        matrix.coef[3][0] = 0;
        matrix.coef[3][1] = 0;
        matrix.coef[3][2] = 0;
        matrix.coef[3][3] = 1;
    }

    return matrix;
}

inverse :: (transform : trf) -> trf {
    result : trf;
    result.rotation = conjugate(transform.rotation);
    if transform.factor == 0. {
        result.factor = 0.;
        result.translation.std = -rotate(transform.translation, result.rotation);
    } else {
        result.factor = 1. / transform.factor;
        result.translation.std = -result.factor * rotate(transform.translation, result.rotation);
    }
    return result;
}

multiply :: (lhs : trf, rhs : trf) -> trf {
    result : trf;
    result.translation.std = lhs.translation + rotate(lhs.factor * rhs.translation, lhs.rotation);
    result.factor = lhs.factor * rhs.factor;
    result.rotation = lhs.rotation * rhs.rotation;
    return result;
}

// Multiply, not considering the Z coordinates. Useful for 2D.
multiply :: (transform : trf, v : $T/interface vec3Interface) -> vec3 {
    result : vec3;
    result.std = transform.translation + rotate(transform.factor * v, transform.rotation);
    return result;
}

operator* :: #procedure_of_call(multiply(trf.{}, trf.{}));

make_scaling_mat3 :: (scaling : vec3) -> mat3 {
    matrix : mat3 = Matrix3_Identity;
    matrix.coef[0][0] = scaling.x;
    matrix.coef[1][1] = scaling.y;
    matrix.coef[2][2] = scaling.z;
    return matrix;
}

make_scaling_mat3 :: (factor : float32) -> mat3 {
    matrix : mat3 = Matrix3_Identity;
    matrix.coef[0][0] = factor;
    matrix.coef[1][1] = factor;
    matrix.coef[2][2] = factor;
    return matrix;
}

copy :: (to: *$T1/interface AnyMatrix3, from: $T2/interface AnyMatrix3) {
    to.coef[0][0] = from.coef[0][0];
    to.coef[0][1] = from.coef[0][1];
    to.coef[0][2] = from.coef[0][2];
    to.coef[1][0] = from.coef[1][0];
    to.coef[1][1] = from.coef[1][1];
    to.coef[1][2] = from.coef[1][2];
    to.coef[2][0] = from.coef[2][0];
    to.coef[2][1] = from.coef[2][1];
    to.coef[2][2] = from.coef[2][2];
}

// Following same conventions as described in infinite_perspective_projection_matrix.
// @note Infinite orthographic projection matrices do not exist
// with a depth information conserved. The best we can is "unnear" it, with a nearClip of 0.
unnear_orthographic_projection_matrix :: (extent : vec2, farClip : float) -> mat4 {
    matrix : mat4;
    unneared_orthographic_projection(*matrix, extent, farClip, false);
    return matrix;
}

unnear_orthographic_projection :: (matrix : *mat4, extent : vec2, farClip : float, $clear := true) {
    #if clear {
        <<matrix = mat4.{};
    }

    matrix.coef[0][0] = 2. / extent.width;
    matrix.coef[1][1] = 2. / extent.height;

    // z' = -z / (f - n) + f / (f - n) which gives z' = -z / f + 1 for an unnear projection.
    matrix.coef[2][2] = - 1. / farClip;
    matrix.coef[2][3] = 1.;
    matrix.coef[3][3] = 1.;
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

// Following same conventions as described in infinite_perspective_projection_matrix.
// @note Angles should be signed. So that, for instance, in a symmetric projection, angleLeft = -angleRight.
infinite_perspective_projection :: (matrix : *mat4, angleLeft : float, angleRight : float,
                                    angleUp : float, angleDown : float, nearClip : float, $clear := true) {
    #if clear {
        <<matrix = mat4.{};
    }

    tanAngleLeft := tan(angleLeft);
    tanAngleRight := tan(angleRight);
    tanAngleUp := tan(angleUp);
    tanAngleDown := tan(angleDown);

    // @note Mappings (once again, angles are signed, so tanAngles are signed too):
    // X * (n / Z) = n*tanAngleLeft  -> X' = -1       X' = (2 * X / Z - (tanAngleRight + tanAngleLeft)) / (tanAngleRight - tanAngleLeft)
    // X * (n / Z) = n*tanAngleRight -> X' =  1
    // Y * (n / Z) = n*tanAngleUp    -> Y' = -1       Y' = (2 * Y / Z - (tanAngleDown + tanAngleUp)) / (tanAngleDown - tanAngleUp)
    // Y * (n / Z) = n*tanAngleDown  -> Y' =  1
    // Z           = n               -> Z' =  1       Z' = n / Z
    // Z           = +infinity       -> Z' =  0
    matrix.coef[0][0] = 2. / (tanAngleRight - tanAngleLeft);
    matrix.coef[0][2] = -(tanAngleRight + tanAngleLeft) / (tanAngleRight - tanAngleLeft);
    matrix.coef[1][1] = 2. / (tanAngleUp - tanAngleDown); // @todo Why not down - up? I thought down was positive, like right.
    matrix.coef[1][2] = -(tanAngleUp + tanAngleDown) / (tanAngleUp - tanAngleDown);
    matrix.coef[2][3] = nearClip;
    matrix.coef[3][2] = 1.;
}

/*
    Get the rotation matrix translated to provided origin
    so that X (forward) becomes the looking direction
    from origin to target.
*/
orientation_matrix :: (origin : vec3, target : vec3, referenceUp := vec3.{0, 0, 1}) -> mat4 {
    matrix : mat4;
    matrix.coef[3][3] = 1;

    forward : vec3;
    forward.std = target - origin;
    normalize(*forward);

    left : vec3;
    left.std = cross_product(referenceUp, forward);
    normalize(*left);

    up : vec3;
    up.std = cross_product(forward.std, left);
    normalize(*up);

    matrix = make_matrix_from_columns(forward, left, up);

    matrix.coef[0][3] = origin.x;
    matrix.coef[1][3] = origin.y;
    matrix.coef[2][3] = origin.z;

    return matrix;
}

inverse_and_prepare_for_projection :: (matrix : mat4) -> mat4 {
    // As described in look_at_matrix, we follow Vulkan's coordinate system.
    // Thus X -> Z ; Y -> -X ; Z -> -Y
    TO_VULKAN_COORDS_MATRIX :: Matrix4.{
        0, -1,  0,  0,
        0,  0, -1,  0,
        1,  0,  0,  0,
        0,  0,  0,  1,
    };
    return multiply(TO_VULKAN_COORDS_MATRIX, inverse(matrix));
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
look_at_matrix :: (origin : vec3, target : vec3, referenceUp := vec3.{0, 0, 1}) -> mat4 {
    matrix := orientation_matrix(origin, target, referenceUp);
    return inverse_and_prepare_for_projection(matrix);
}

#scope_file

#import "Math";
