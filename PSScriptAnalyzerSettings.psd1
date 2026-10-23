@{
    ExcludeRules = @(
        # Script parameters (FontSize, Margin, ...) are used inside functions, which this rule can't see.
        'PSReviewUnusedParameter'
        # Internal helpers in a script, not exported cmdlets; -WhatIf support adds nothing here.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
