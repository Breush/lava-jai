
CHECK :: (ok : bool, returnedValue : $T, message : ..Any) #expand {
    if !ok {
        // @todo Use official context logger.
        Chamber.debug(..message);
        Chamber.debug("\n");
        `return returnedValue;
    }
}

RESULT_CHECK :: (result : Vk.Result, returnedValue : $T, message : string) #expand {
    CHECK(result == Vk.Result.Success, returnedValue, message, "(", result, ")");
}

RESULT_CHECK :: (result : Vk.Result, message : string) #expand {
    RESULT_CHECK(result, false, message);
}
