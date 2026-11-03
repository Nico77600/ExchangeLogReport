public static class SmtpProcessMemory
{
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct Counters
    {
        public uint Size, PageFaultCount;
        public System.UIntPtr PeakWorkingSet, WorkingSet, PeakPagedPool, PagedPool;
        public System.UIntPtr PeakNonPagedPool, NonPagedPool, Pagefile, PeakPagefile, PrivateUsage;
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", EntryPoint = "K32GetProcessMemoryInfo", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    static extern bool ReadMemory(System.IntPtr process, ref Counters counters, uint size);

    static readonly uint CounterBytes = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Counters>();

    // Process.Refresh builds a managed process snapshot; that garbage must not be attributed to the measured workload.
    public static long PrivateBytes()
    {
        var counters = new Counters { Size = CounterBytes };
        if (!ReadMemory(new System.IntPtr(-1), ref counters, CounterBytes))
            throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
        return checked((long)counters.PrivateUsage.ToUInt64());
    }

    public static long ReadAllocations(int samples)
    {
        if (samples < 1) throw new System.ArgumentOutOfRangeException(nameof(samples));
        for (int i = 0; i < 10; i++) PrivateBytes();
        long start = System.GC.GetAllocatedBytesForCurrentThread();
        for (int i = 0; i < samples; i++) PrivateBytes();
        return System.GC.GetAllocatedBytesForCurrentThread() - start;
    }
}
