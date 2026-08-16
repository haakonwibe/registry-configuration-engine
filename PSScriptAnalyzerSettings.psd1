@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Generator's user-facing console output uses Write-Host intentionally.
        'PSAvoidUsingWriteHost',

        # Project convention is BOM-less UTF-8 (matches the user's editor default
        # and avoids spurious diffs on tools that strip BOM).
        'PSUseBOMForUnicodeEncodedFile',

        # 'Write-Log' is a script-scoped helper, not a built-in we ship over.
        # The analyzer flags it because newer modules added a Write-Log; not relevant here.
        'PSAvoidOverwritingBuiltInCmdlets',

        # Function names like Get-UserProfileSIDs and Expand-ConfigVariables describe
        # operations that return collections — singular nouns would misrepresent.
        'PSUseSingularNouns',

        # Engine entry script declares params used by callees via $script:* scope;
        # analyzer can't always trace this through, producing false positives.
        'PSReviewUnusedParameter',

        # SupportsShouldProcess is set on the entry script and the main mutating
        # functions. Analyzer flags helpers in between as if they need it too.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
