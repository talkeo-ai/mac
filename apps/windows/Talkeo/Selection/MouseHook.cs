using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Talkeo.Interop;

namespace Talkeo.Selection;

/// <summary>
/// Global low-level mouse hook (WH_MOUSE_LL). Fires the callback on mouse-up
/// when the gesture looks like a text selection (drag with non-zero distance).
/// The hook runs on its own dedicated thread so heavy work on the UI thread
/// can never block input.
/// </summary>
internal sealed class MouseHook
{
    private readonly Action<int, int> _onSelectionGesture;
    private NativeMethods.HookProc? _proc;
    private IntPtr _hookId = IntPtr.Zero;
    private Thread? _thread;
    private NativeMethods.POINT _downPoint;
    private bool _isDown;
    private bool _didDrag;

    public MouseHook(Action<int, int> onSelectionGesture)
    {
        _onSelectionGesture = onSelectionGesture;
    }

    public void Start()
    {
        if (_thread != null) return;
        _thread = new Thread(RunHookThread)
        {
            IsBackground = true,
            Name = "Talkeo.MouseHook",
        };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
    }

    public void Stop()
    {
        if (_hookId != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(_hookId);
            _hookId = IntPtr.Zero;
        }
    }

    private void RunHookThread()
    {
        _proc = HookCallback;
        var hModule = NativeMethods.GetModuleHandle(null);
        _hookId = NativeMethods.SetWindowsHookEx(NativeMethods.WH_MOUSE_LL, _proc, hModule, 0);
        if (_hookId == IntPtr.Zero)
        {
            Debug.WriteLine("[Talkeo] SetWindowsHookEx failed");
            return;
        }
        Debug.WriteLine("[Talkeo] mouse hook installed");

        // Pump messages so the hook callback fires.
        var msg = new MSG();
        while (NativeMethods_GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
        {
            NativeMethods_TranslateMessage(ref msg);
            NativeMethods_DispatchMessage(ref msg);
        }
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return NativeMethods.CallNextHookEx(_hookId, nCode, wParam, lParam);

        int message = wParam.ToInt32();
        if (message == NativeMethods.WM_LBUTTONDOWN)
        {
            var data = MarshalHook(lParam);
            _downPoint = data.pt;
            _isDown = true;
            _didDrag = false;
        }
        else if (message == NativeMethods.WM_MOUSEMOVE && _isDown)
        {
            var data = MarshalHook(lParam);
            int dx = data.pt.X - _downPoint.X;
            int dy = data.pt.Y - _downPoint.Y;
            if (dx * dx + dy * dy > 9) _didDrag = true;
        }
        else if (message == NativeMethods.WM_LBUTTONUP)
        {
            var data = MarshalHook(lParam);
            bool gesture = _isDown && _didDrag;
            int x = data.pt.X;
            int y = data.pt.Y;
            _isDown = false;
            _didDrag = false;
            if (gesture)
            {
                // Marshal off the hook thread so a slow UIA call cannot stall input.
                ThreadPool.QueueUserWorkItem(_ => _onSelectionGesture(x, y));
            }
        }

        return NativeMethods.CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    private static NativeMethods.MSLLHOOKSTRUCT MarshalHook(IntPtr lParam)
        => Marshal.PtrToStructure<NativeMethods.MSLLHOOKSTRUCT>(lParam);

    // Minimal message pump bindings (kept private to this file).
    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public NativeMethods.POINT pt;
        public uint lPrivate;
    }

    [DllImport("user32.dll", EntryPoint = "GetMessageW")]
    private static extern int NativeMethods_GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool NativeMethods_TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll", EntryPoint = "DispatchMessageW")]
    private static extern IntPtr NativeMethods_DispatchMessage(ref MSG lpMsg);
}
