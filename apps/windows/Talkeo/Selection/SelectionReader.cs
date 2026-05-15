using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Talkeo.Selection;

/// <summary>
/// Reads currently-selected text in any foreground window via UI Automation.
/// Strategy: walk to the focused element, ask for its TextPattern, and read
/// the first selection range. Many controls support this directly (Edge,
/// Win32 EDIT/RICHEDIT, WinUI/UWP, Office). Apps without TextPattern return
/// null and the caller should ignore the event.
///
/// We use late-bound COM through dynamic dispatch to avoid taking a hard
/// dependency on a specific interop assembly version.
/// </summary>
internal sealed class SelectionReader
{
    private readonly dynamic? _automation;

    public SelectionReader()
    {
        try
        {
            var type = Type.GetTypeFromCLSID(new Guid("FF48DBA4-60EF-4201-AA87-54103EEF594E"));
            if (type != null)
            {
                _automation = Activator.CreateInstance(type);
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Talkeo] CUIAutomation create failed: {ex.Message}");
        }
    }

    public string? ReadSelectedText()
    {
        if (_automation == null) return null;
        try
        {
            dynamic? focused = _automation.GetFocusedElement();
            if (focused == null) return null;

            // UIA_TextPatternId = 10014
            object? raw = focused.GetCurrentPattern(10014);
            if (raw == null) return null;

            dynamic pattern = raw;
            dynamic ranges = pattern.GetSelection();
            int length = (int)ranges.Length;
            if (length == 0) return null;

            dynamic range = ranges.GetElement(0);
            // -1 -> unbounded
            string? text = (string?)range.GetText(-1);
            if (string.IsNullOrEmpty(text)) return null;
            return text;
        }
        catch (COMException ex)
        {
            Debug.WriteLine($"[Talkeo] UIA selection read COM error: 0x{ex.HResult:X}");
            return null;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Talkeo] UIA selection read failed: {ex.Message}");
            return null;
        }
    }
}
