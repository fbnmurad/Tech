using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using Microsoft.Win32;
using System.Net.NetworkInformation;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace InformacoesMaquinaUsuario
{
    internal sealed class NetworkInfo
    {
        public string InterfaceAlias;
        public int InterfaceIndex;
        public string AdapterName;
        public string AdapterStatus;
        public string NetworkName;
        public string NetworkCategory;
        public string IPv4;
        public string PrefixLength;
        public string Gateway;
        public string DnsServers;
        public string MacAddress;
        public bool IsPrimary;
    }

    internal sealed class Program
    {
        private const string PackageVersion = "2026.07.15.13";

        private static int Main(string[] args)
        {
            bool noPause = args.Any(delegate(string a)
            {
                return string.Equals(a, "--nopause", StringComparison.OrdinalIgnoreCase) ||
                       string.Equals(a, "/nopause", StringComparison.OrdinalIgnoreCase) ||
                       string.Equals(a, "-nopause", StringComparison.OrdinalIgnoreCase);
            });
            bool saveOnly = HasArgument(args, "--saveonly") || HasArgument(args, "/saveonly");
            bool consoleMode = HasArgument(args, "--console") || HasArgument(args, "/console");

            string machineOverride = GetArgumentValue(args, "--machine");
            string userOverride = GetArgumentValue(args, "--user");

            try
            {
                Console.OutputEncoding = new UTF8Encoding(false);
            }
            catch
            {
            }

            try
            {
                List<string> lines = BuildReport(machineOverride, userOverride);
                string reportPath = SaveReport(lines);

                if (saveOnly || noPause || consoleMode)
                {
                    try
                    {
                        Console.Clear();
                    }
                    catch
                    {
                    }

                    foreach (string line in lines)
                    {
                        Console.WriteLine(line);
                    }

                    Console.WriteLine();
                    if (IsCurrentUserAdministrator())
                    {
                        Console.ForegroundColor = ConsoleColor.Green;
                        Console.WriteLine("Relatório salvo em:");
                        Console.ResetColor();
                        Console.ForegroundColor = ConsoleColor.Cyan;
                        Console.WriteLine(reportPath);
                        Console.ResetColor();
                    }
                    else
                    {
                        Console.ForegroundColor = ConsoleColor.Green;
                        Console.WriteLine("Relatório salvo automaticamente.");
                        Console.ResetColor();
                    }

                    if (!noPause && !saveOnly)
                    {
                        Console.WriteLine();
                        Console.Write("Pressione ENTER para fechar...");
                        Console.ReadLine();
                    }

                    return 0;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new InfoForm(lines, reportPath));
                return 0;
            }
            catch (Exception ex)
            {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine("Falha ao coletar informações: " + ex.Message);
                Console.ResetColor();

                if (!noPause)
                {
                    Console.WriteLine();
                    Console.Write("Pressione ENTER para fechar...");
                    Console.ReadLine();
                }

                return 1;
            }
        }

        internal static bool IsCurrentUserAdministrator()
        {
            try
            {
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                {
                    WindowsPrincipal principal = new WindowsPrincipal(identity);
                    return principal.IsInRole(WindowsBuiltInRole.Administrator);
                }
            }
            catch
            {
                return false;
            }
        }

        private static List<string> BuildReport(string machineOverride, string userOverride)
        {
            DateTime now = DateTime.Now;
            ManagementObject computerSystem = FirstWmi(@"\\.\root\cimv2", "SELECT * FROM Win32_ComputerSystem");
            ManagementObject bios = FirstWmi(@"\\.\root\cimv2", "SELECT * FROM Win32_BIOS");
            ManagementObject os = FirstWmi(@"\\.\root\cimv2", "SELECT * FROM Win32_OperatingSystem");

            DateTime? lastBoot = GetLastBoot(os);
            string uptimeText = "Não identificado";
            if (lastBoot.HasValue)
            {
                uptimeText = FormatTimeSpan(now - lastBoot.Value);
            }

            string machineName = GetMachineName(computerSystem, machineOverride);
            string currentIdentity = GetCurrentIdentity();
            string loggedUser = GetLoggedUser(computerSystem, currentIdentity, userOverride);

            List<NetworkInfo> activeNetworks = GetActiveNetworks();
            NetworkInfo primaryNetwork = activeNetworks.FirstOrDefault(delegate(NetworkInfo n) { return n.IsPrimary; });
            if (primaryNetwork == null)
            {
                primaryNetwork = activeNetworks.FirstOrDefault(delegate(NetworkInfo n) { return n.Gateway != "Não identificado"; });
            }
            if (primaryNetwork == null)
            {
                primaryNetwork = activeNetworks.FirstOrDefault();
            }

            List<string> wifiSsids = GetWifiSsids();
            string wifiText = wifiSsids.Count > 0 ? string.Join(", ", wifiSsids.ToArray()) : "Não identificado";
            if (wifiText == "Não identificado" && primaryNetwork != null && IsWifiName(primaryNetwork.InterfaceAlias))
            {
                wifiText = ValueOrDefault(primaryNetwork.NetworkName);
            }

            string model = ValueOrDefault(GetWmiString(computerSystem, "Model"));
            string serialNumber = ValueOrDefault(GetWmiString(bios, "SerialNumber"));
            string primaryNetworkName = primaryNetwork != null ? ValueOrDefault(primaryNetwork.NetworkName) : "Não identificado";
            string primaryIPv4 = primaryNetwork != null ? ValueOrDefault(primaryNetwork.IPv4) : "Não identificado";
            string lastBootText = lastBoot.HasValue ? lastBoot.Value.ToString("dd/MM/yyyy HH:mm:ss") : "Não identificado";

            List<string> lines = new List<string>();
            AddLine(lines, "============================================================");
            AddLine(lines, " ESTAÇÃO DE TRABALHO");
            AddLine(lines, "============================================================");
            AddLine(lines, "");
            AddKeyValue(lines, "Versão do pacote", PackageVersion);
            AddKeyValue(lines, "Nome da máquina", machineName);
            AddKeyValue(lines, "Usuário logado", loggedUser);
            AddKeyValue(lines, "Modelo", model);
            AddKeyValue(lines, "Número de série", serialNumber);
            AddKeyValue(lines, "IP IPv4", primaryIPv4);
            AddKeyValue(lines, "Nome da rede", primaryNetworkName);
            AddKeyValue(lines, "Última reinicialização", lastBootText);
            AddKeyValue(lines, "Tempo sem reiniciar", uptimeText);
            AddKeyValue(lines, "Data da coleta", now.ToString("dd/MM/yyyy HH:mm:ss"));
            AddLine(lines, "");

            AddLine(lines, "COMPUTADOR");
            AddKeyValue(lines, "Nome da máquina", machineName);
            AddKeyValue(lines, "Nome do computador", machineName);
            AddKeyValue(lines, "Nome via ambiente", Environment.MachineName);
            AddKeyValue(lines, "Nome via WMI", GetWmiString(computerSystem, "Name"));
            AddKeyValue(lines, "Fabricante", GetWmiString(computerSystem, "Manufacturer"));
            AddKeyValue(lines, "Modelo", model);
            AddKeyValue(lines, "Número de série", serialNumber);
            AddKeyValue(lines, "Domínio/Grupo de trabalho", GetWmiString(computerSystem, "Domain"));
            AddKeyValue(lines, "Usuário logado", loggedUser);
            AddKeyValue(lines, "Usuário do processo", currentIdentity);
            AddLine(lines, "");

            AddLine(lines, "WINDOWS");
            AddKeyValue(lines, "Sistema", GetWmiString(os, "Caption"));
            AddKeyValue(lines, "Versão", GetWmiString(os, "Version"));
            AddKeyValue(lines, "Build", GetWmiString(os, "BuildNumber"));
            AddKeyValue(lines, "Arquitetura", GetWmiString(os, "OSArchitecture"));
            AddKeyValue(lines, "Última reinicialização", lastBootText);
            AddKeyValue(lines, "Tempo sem reiniciar", uptimeText);
            AddLine(lines, "");

            AddLine(lines, "REDE PRINCIPAL");
            if (primaryNetwork != null)
            {
                AddKeyValue(lines, "Nome da rede", primaryNetwork.NetworkName);
                AddKeyValue(lines, "SSID Wi-Fi", wifiText);
                AddKeyValue(lines, "Interface", primaryNetwork.InterfaceAlias);
                AddKeyValue(lines, "Categoria", primaryNetwork.NetworkCategory);
                AddKeyValue(lines, "IP IPv4", primaryNetwork.IPv4);
                AddKeyValue(lines, "Gateway", primaryNetwork.Gateway);
                AddKeyValue(lines, "DNS", primaryNetwork.DnsServers);
                AddKeyValue(lines, "MAC", primaryNetwork.MacAddress);
            }
            else
            {
                AddLine(lines, "Nenhuma conexão IPv4 ativa foi identificada.");
            }
            AddLine(lines, "");

            AddLine(lines, "TODAS AS CONEXÕES IPv4 ATIVAS");
            if (activeNetworks.Count > 0)
            {
                foreach (NetworkInfo item in activeNetworks)
                {
                    string marker = item.IsPrimary ? "principal" : "ativa";
                    AddLine(lines, string.Format("- {0} [{1}] | Rede: {2} | IP: {3} | Gateway: {4}",
                        ValueOrDefault(item.InterfaceAlias),
                        marker,
                        ValueOrDefault(item.NetworkName),
                        ValueOrDefault(item.IPv4),
                        ValueOrDefault(item.Gateway)));
                }
            }
            else
            {
                AddLine(lines, "- Nenhuma conexão IPv4 ativa encontrada.");
            }

            AddLine(lines, "");
            AddLine(lines, "CONFIRMAÇÃO DOS CAMPOS PEDIDOS");
            AddKeyValue(lines, "Nome da máquina", machineName);
            AddKeyValue(lines, "Usuário logado", loggedUser);
            AddKeyValue(lines, "Modelo", model);
            AddKeyValue(lines, "Número de série", serialNumber);
            AddKeyValue(lines, "IP IPv4", primaryIPv4);
            AddKeyValue(lines, "Nome da rede", primaryNetworkName);
            AddKeyValue(lines, "Tempo sem reiniciar", uptimeText);
            AddLine(lines, "");
            AddLine(lines, "Observação: este executável é somente leitura. Nenhuma configuração foi alterada.");

            return lines;
        }

        private static string SaveReport(List<string> lines)
        {
            string outputDirectory = GetApplicationOutputDirectory();

            string safeComputerName = Regex.Replace(Environment.MachineName, @"[^\w.-]", "_");
            string fileName = string.Format("Informacoes_Maquina_{0}_{1}.txt", safeComputerName, DateTime.Now.ToString("yyyyMMdd_HHmmss"));
            string reportPath = Path.Combine(outputDirectory, fileName);

            try
            {
                File.WriteAllLines(reportPath, lines.ToArray(), new UTF8Encoding(true));
                return reportPath;
            }
            catch
            {
                reportPath = Path.Combine(Path.GetTempPath(), fileName);
                File.WriteAllLines(reportPath, lines.ToArray(), new UTF8Encoding(true));
                return reportPath;
            }
        }

        private static string GetApplicationOutputDirectory()
        {
            string outputDirectory = null;

            try
            {
                outputDirectory = Path.GetDirectoryName(typeof(Program).Assembly.Location);
            }
            catch
            {
            }

            if (string.IsNullOrWhiteSpace(outputDirectory) || !Directory.Exists(outputDirectory))
            {
                outputDirectory = AppDomain.CurrentDomain.BaseDirectory;
            }

            if (string.IsNullOrWhiteSpace(outputDirectory) || !Directory.Exists(outputDirectory))
            {
                outputDirectory = Directory.GetCurrentDirectory();
            }

            if (string.IsNullOrWhiteSpace(outputDirectory) || !Directory.Exists(outputDirectory))
            {
                outputDirectory = Path.GetTempPath();
            }

            return outputDirectory;
        }

        private static bool HasArgument(string[] args, string name)
        {
            if (args == null || args.Length == 0)
            {
                return false;
            }

            foreach (string arg in args)
            {
                if (string.Equals(arg, name, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }

        private static string GetArgumentValue(string[] args, string name)
        {
            if (args == null || args.Length == 0)
            {
                return null;
            }

            for (int i = 0; i < args.Length; i++)
            {
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    return args[i + 1];
                }

                string prefix = name + "=";
                if (args[i].StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                {
                    return args[i].Substring(prefix.Length).Trim('"');
                }
            }

            return null;
        }

        private static string GetMachineName(ManagementObject computerSystem, string explicitMachineName)
        {
            List<string> candidates = new List<string>();
            candidates.Add(explicitMachineName);
            candidates.Add(Environment.MachineName);
            candidates.Add(Environment.GetEnvironmentVariable("COMPUTERNAME"));
            candidates.Add(GetWmiString(computerSystem, "Name"));

            try
            {
                candidates.Add(IPGlobalProperties.GetIPGlobalProperties().HostName);
            }
            catch
            {
            }

            return FirstUsable(candidates, "Não identificado");
        }

        private static string GetCurrentIdentity()
        {
            try
            {
                return ValueOrDefault(WindowsIdentity.GetCurrent().Name);
            }
            catch
            {
                return GetEnvironmentUser();
            }
        }

        private static string GetLoggedUser(ManagementObject computerSystem, string currentIdentity, string explicitUser)
        {
            List<string> candidates = new List<string>();
            candidates.Add(explicitUser);
            candidates.Add(GetWmiString(computerSystem, "UserName"));
            candidates.Add(GetExplorerOwner());
            candidates.Add(GetHkcuVolatileUser());
            candidates.Add(GetEnvironmentUser());
            candidates.Add(currentIdentity);

            return FirstUsable(candidates, "Não identificado");
        }

        private static string GetEnvironmentUser()
        {
            List<string> candidates = new List<string>();

            try
            {
                string domain = Environment.UserDomainName;
                string user = Environment.UserName;
                if (!string.IsNullOrWhiteSpace(domain) && !string.IsNullOrWhiteSpace(user))
                {
                    candidates.Add(domain + "\\" + user);
                }
            }
            catch
            {
            }

            string envDomain = Environment.GetEnvironmentVariable("USERDOMAIN");
            string envUser = Environment.GetEnvironmentVariable("USERNAME");
            if (!string.IsNullOrWhiteSpace(envDomain) && !string.IsNullOrWhiteSpace(envUser))
            {
                candidates.Add(envDomain + "\\" + envUser);
            }

            if (!string.IsNullOrWhiteSpace(envUser))
            {
                candidates.Add(envUser);
            }

            return FirstUsable(candidates, "Não identificado");
        }

        private static string GetHkcuVolatileUser()
        {
            List<string> candidates = new List<string>();

            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey("Volatile Environment"))
                {
                    AddVolatileEnvironmentUser(key, candidates);

                    if (key != null)
                    {
                        foreach (string subKeyName in key.GetSubKeyNames())
                        {
                            using (RegistryKey subKey = key.OpenSubKey(subKeyName))
                            {
                                AddVolatileEnvironmentUser(subKey, candidates);
                            }
                        }
                    }
                }
            }
            catch
            {
            }

            return FirstUsable(candidates, null);
        }

        private static void AddVolatileEnvironmentUser(RegistryKey key, List<string> candidates)
        {
            if (key == null)
            {
                return;
            }

            string domain = Convert.ToString(key.GetValue("USERDOMAIN"));
            string user = Convert.ToString(key.GetValue("USERNAME"));
            if (!string.IsNullOrWhiteSpace(domain) && !string.IsNullOrWhiteSpace(user))
            {
                candidates.Add(domain + "\\" + user);
            }
            else if (!string.IsNullOrWhiteSpace(user))
            {
                candidates.Add(user);
            }
        }

        private static string GetExplorerOwner()
        {
            List<Tuple<int, string>> candidates = new List<Tuple<int, string>>();
            int currentSessionId = -1;

            try
            {
                currentSessionId = Process.GetCurrentProcess().SessionId;
            }
            catch
            {
            }

            try
            {
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(@"\\.\root\cimv2", "SELECT ProcessId, SessionId FROM Win32_Process WHERE Name = 'explorer.exe'"))
                using (ManagementObjectCollection collection = searcher.Get())
                {
                    foreach (ManagementObject process in collection)
                    {
                        string owner = GetProcessOwner(process);
                        if (string.IsNullOrWhiteSpace(owner))
                        {
                            continue;
                        }

                        int sessionId = GetWmiInt(process, "SessionId");
                        candidates.Add(Tuple.Create(sessionId, owner));
                    }
                }
            }
            catch
            {
            }

            Tuple<int, string> sameSession = candidates.FirstOrDefault(delegate(Tuple<int, string> item)
            {
                return item.Item1 == currentSessionId;
            });

            if (sameSession != null)
            {
                return sameSession.Item2;
            }

            return candidates.Count > 0 ? candidates[0].Item2 : null;
        }

        private static string GetProcessOwner(ManagementObject process)
        {
            try
            {
                object[] args = new object[] { string.Empty, string.Empty };
                object result = process.InvokeMethod("GetOwner", args);
                int returnCode = result == null ? -1 : Convert.ToInt32(result);
                if (returnCode != 0)
                {
                    return null;
                }

                string user = Convert.ToString(args[0]);
                string domain = Convert.ToString(args[1]);
                if (!string.IsNullOrWhiteSpace(domain) && !string.IsNullOrWhiteSpace(user))
                {
                    return domain + "\\" + user;
                }

                return user;
            }
            catch
            {
                return null;
            }
        }

        private static List<NetworkInfo> GetActiveNetworks()
        {
            Dictionary<int, Tuple<string, string>> profiles = GetNetworkProfiles();
            Dictionary<int, string> adapterAliases = GetAdapterAliases();
            List<NetworkInfo> networks = new List<NetworkInfo>();

            try
            {
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(@"\\.\root\cimv2", "SELECT * FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled = True"))
                using (ManagementObjectCollection collection = searcher.Get())
                {
                    foreach (ManagementObject cfg in collection)
                    {
                        string ipv4 = JoinIPv4(GetWmiStringArray(cfg, "IPAddress"));
                        if (string.IsNullOrWhiteSpace(ipv4))
                        {
                            continue;
                        }

                        int interfaceIndex = GetWmiInt(cfg, "InterfaceIndex");
                        string alias = adapterAliases.ContainsKey(interfaceIndex) ? adapterAliases[interfaceIndex] : GetWmiString(cfg, "Description");
                        string profileName = "Não identificado";
                        string category = "Não identificado";
                        if (profiles.ContainsKey(interfaceIndex))
                        {
                            profileName = profiles[interfaceIndex].Item1;
                            category = profiles[interfaceIndex].Item2;
                        }

                        string gateway = JoinIPv4(GetWmiStringArray(cfg, "DefaultIPGateway"));
                        string dns = JoinIPv4(GetWmiStringArray(cfg, "DNSServerSearchOrder"));
                        string mac = GetWmiString(cfg, "MACAddress");

                        if (profileName == "Não identificado")
                        {
                            profileName = IsWifiName(alias) ? FirstOrDefault(GetWifiSsids(), "Não identificado") : alias;
                        }

                        networks.Add(new NetworkInfo
                        {
                            InterfaceAlias = ValueOrDefault(alias),
                            InterfaceIndex = interfaceIndex,
                            AdapterName = ValueOrDefault(GetWmiString(cfg, "Description")),
                            AdapterStatus = "Ativo",
                            NetworkName = ValueOrDefault(profileName),
                            NetworkCategory = ValueOrDefault(category),
                            IPv4 = ValueOrDefault(ipv4),
                            PrefixLength = "Não identificado",
                            Gateway = ValueOrDefault(gateway),
                            DnsServers = ValueOrDefault(dns),
                            MacAddress = ValueOrDefault(mac),
                            IsPrimary = !string.IsNullOrWhiteSpace(gateway)
                        });
                    }
                }
            }
            catch
            {
            }

            bool alreadyMarkedPrimary = false;
            foreach (NetworkInfo network in networks)
            {
                if (network.IsPrimary && !alreadyMarkedPrimary)
                {
                    alreadyMarkedPrimary = true;
                    continue;
                }

                network.IsPrimary = false;
            }

            return networks;
        }

        private static Dictionary<int, Tuple<string, string>> GetNetworkProfiles()
        {
            Dictionary<int, Tuple<string, string>> profiles = new Dictionary<int, Tuple<string, string>>();

            try
            {
                ManagementScope scope = new ManagementScope(@"\\.\root\StandardCimv2");
                scope.Connect();
                ObjectQuery query = new ObjectQuery("SELECT InterfaceIndex, Name, NetworkCategory FROM MSFT_NetConnectionProfile");
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(scope, query))
                using (ManagementObjectCollection collection = searcher.Get())
                {
                    foreach (ManagementObject profile in collection)
                    {
                        int interfaceIndex = GetWmiInt(profile, "InterfaceIndex");
                        string name = ValueOrDefault(GetWmiString(profile, "Name"));
                        string category = NetworkCategoryName(GetWmiString(profile, "NetworkCategory"));
                        if (interfaceIndex > 0 && !profiles.ContainsKey(interfaceIndex))
                        {
                            profiles.Add(interfaceIndex, Tuple.Create(name, category));
                        }
                    }
                }
            }
            catch
            {
            }

            return profiles;
        }

        private static Dictionary<int, string> GetAdapterAliases()
        {
            Dictionary<int, string> aliases = new Dictionary<int, string>();

            try
            {
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(@"\\.\root\cimv2", "SELECT InterfaceIndex, NetConnectionID, Name FROM Win32_NetworkAdapter WHERE NetEnabled = True"))
                using (ManagementObjectCollection collection = searcher.Get())
                {
                    foreach (ManagementObject adapter in collection)
                    {
                        int interfaceIndex = GetWmiInt(adapter, "InterfaceIndex");
                        string alias = GetWmiString(adapter, "NetConnectionID");
                        if (string.IsNullOrWhiteSpace(alias))
                        {
                            alias = GetWmiString(adapter, "Name");
                        }

                        if (interfaceIndex > 0 && !aliases.ContainsKey(interfaceIndex))
                        {
                            aliases.Add(interfaceIndex, ValueOrDefault(alias));
                        }
                    }
                }
            }
            catch
            {
            }

            return aliases;
        }

        private static List<string> GetWifiSsids()
        {
            List<string> ssids = new List<string>();

            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "netsh.exe";
                psi.Arguments = "wlan show interfaces";
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.CreateNoWindow = true;

                using (Process process = Process.Start(psi))
                {
                    string output = process.StandardOutput.ReadToEnd();
                    process.WaitForExit(3000);

                    string[] lines = output.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
                    foreach (string line in lines)
                    {
                        Match match = Regex.Match(line, @"^\s*SSID\s*:\s*(.+?)\s*$", RegexOptions.IgnoreCase);
                        if (match.Success)
                        {
                            string ssid = match.Groups[1].Value.Trim();
                            if (!string.IsNullOrWhiteSpace(ssid) &&
                                !string.Equals(ssid, "N/A", StringComparison.OrdinalIgnoreCase) &&
                                !ssids.Contains(ssid))
                            {
                                ssids.Add(ssid);
                            }
                        }
                    }
                }
            }
            catch
            {
            }

            return ssids;
        }

        private static ManagementObject FirstWmi(string scopePath, string query)
        {
            try
            {
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(scopePath, query))
                using (ManagementObjectCollection collection = searcher.Get())
                {
                    foreach (ManagementObject item in collection)
                    {
                        return item;
                    }
                }
            }
            catch
            {
            }

            return null;
        }

        private static DateTime? GetLastBoot(ManagementObject os)
        {
            string raw = GetWmiString(os, "LastBootUpTime");
            if (string.IsNullOrWhiteSpace(raw))
            {
                return null;
            }

            try
            {
                return ManagementDateTimeConverter.ToDateTime(raw);
            }
            catch
            {
                return null;
            }
        }

        private static string FormatTimeSpan(TimeSpan value)
        {
            List<string> parts = new List<string>();
            if (value.Days > 0)
            {
                parts.Add(string.Format("{0} dia(s)", value.Days));
            }

            if (value.Hours > 0 || parts.Count > 0)
            {
                parts.Add(string.Format("{0} hora(s)", value.Hours));
            }

            parts.Add(string.Format("{0} minuto(s)", value.Minutes));
            return string.Join(", ", parts.ToArray());
        }

        private static string GetWmiString(ManagementBaseObject obj, string propertyName)
        {
            if (obj == null)
            {
                return null;
            }

            try
            {
                object value = obj[propertyName];
                return value == null ? null : Convert.ToString(value);
            }
            catch
            {
                return null;
            }
        }

        private static string[] GetWmiStringArray(ManagementBaseObject obj, string propertyName)
        {
            if (obj == null)
            {
                return new string[0];
            }

            try
            {
                object value = obj[propertyName];
                if (value == null)
                {
                    return new string[0];
                }

                string[] stringArray = value as string[];
                if (stringArray != null)
                {
                    return stringArray;
                }

                object[] objectArray = value as object[];
                if (objectArray != null)
                {
                    return objectArray.Select(delegate(object item) { return Convert.ToString(item); }).ToArray();
                }
            }
            catch
            {
            }

            return new string[0];
        }

        private static int GetWmiInt(ManagementBaseObject obj, string propertyName)
        {
            string value = GetWmiString(obj, propertyName);
            int result;
            return int.TryParse(value, out result) ? result : 0;
        }

        private static string JoinIPv4(string[] values)
        {
            return string.Join(", ", values.Where(delegate(string item)
            {
                if (string.IsNullOrWhiteSpace(item))
                {
                    return false;
                }

                IPAddressVersion version = GetIpVersion(item);
                return version == IPAddressVersion.IPv4 &&
                       item != "127.0.0.1" &&
                       !item.StartsWith("169.254.", StringComparison.OrdinalIgnoreCase);
            }).ToArray());
        }

        private static string JoinNonEmpty(string[] values)
        {
            return string.Join(", ", values.Where(delegate(string item)
            {
                return !string.IsNullOrWhiteSpace(item);
            }).ToArray());
        }

        private static IPAddressVersion GetIpVersion(string address)
        {
            if (Regex.IsMatch(address, @"^\d{1,3}(\.\d{1,3}){3}$"))
            {
                return IPAddressVersion.IPv4;
            }

            return IPAddressVersion.Other;
        }

        private static bool IsWifiName(string name)
        {
            if (string.IsNullOrWhiteSpace(name))
            {
                return false;
            }

            return Regex.IsMatch(name, @"wi-?fi|wireless|wlan|sem fio", RegexOptions.IgnoreCase);
        }

        private static string NetworkCategoryName(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw))
            {
                return "Não identificado";
            }

            if (raw == "0")
            {
                return "Public";
            }

            if (raw == "1")
            {
                return "Private";
            }

            if (raw == "2")
            {
                return "DomainAuthenticated";
            }

            return raw;
        }

        private static string FirstOrDefault(List<string> values, string fallback)
        {
            return values.Count > 0 ? values[0] : fallback;
        }

        private static string FirstUsable(IEnumerable<string> values, string fallback)
        {
            foreach (string value in values)
            {
                if (!string.IsNullOrWhiteSpace(value) &&
                    !string.Equals(value.Trim(), "Não identificado", StringComparison.OrdinalIgnoreCase))
                {
                    return value.Trim();
                }
            }

            return fallback;
        }

        private static string ValueOrDefault(object value)
        {
            return ValueOrDefault(value, "Não identificado");
        }

        private static string ValueOrDefault(object value, string fallback)
        {
            if (value == null)
            {
                return fallback;
            }

            string text = Convert.ToString(value);
            return string.IsNullOrWhiteSpace(text) ? fallback : text.Trim();
        }

        private static void AddLine(List<string> lines, string text)
        {
            lines.Add(text ?? string.Empty);
        }

        private static void AddKeyValue(List<string> lines, string key, object value)
        {
            lines.Add(string.Format("{0,-28}: {1}", key, ValueOrDefault(value)));
        }

        private enum IPAddressVersion
        {
            Other,
            IPv4
        }
    }

    internal sealed class BrandHeaderPanel : Panel
    {
        private static readonly Color BrandBlue = Color.FromArgb(0, 70, 156);
        private static readonly Color BrandDeepBlue = Color.FromArgb(0, 54, 135);
        private static readonly Color BrandYellow = Color.FromArgb(255, 198, 0);
        private static readonly Color BrandRed = Color.FromArgb(207, 28, 35);
        private static readonly Color BrandCream = Color.FromArgb(255, 250, 242);

        public BrandHeaderPanel()
        {
            DoubleBuffered = true;
            BackColor = BrandCream;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);

            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = ClientRectangle;

            using (LinearGradientBrush bg = new LinearGradientBrush(bounds, Color.White, BrandCream, LinearGradientMode.Horizontal))
            {
                g.FillRectangle(bg, bounds);
            }

            using (GraphicsPath yellowWave = new GraphicsPath())
            {
                yellowWave.StartFigure();
                yellowWave.AddLine(0, 0, bounds.Width, 0);
                yellowWave.AddLine(bounds.Width, 0, bounds.Width, 18);
                yellowWave.AddBezier(bounds.Width, 18, bounds.Width * 3 / 4, 52, bounds.Width / 3, 18, 0, 48);
                yellowWave.CloseFigure();
                using (SolidBrush brush = new SolidBrush(BrandYellow))
                {
                    g.FillPath(brush, yellowWave);
                }
            }

            using (GraphicsPath blueWave = new GraphicsPath())
            {
                blueWave.StartFigure();
                blueWave.AddLine(0, bounds.Height, bounds.Width, bounds.Height);
                blueWave.AddLine(bounds.Width, bounds.Height, bounds.Width, bounds.Height - 50);
                blueWave.AddBezier(bounds.Width, bounds.Height - 50, bounds.Width * 2 / 3, bounds.Height - 4, bounds.Width / 3, bounds.Height - 66, 0, bounds.Height - 28);
                blueWave.CloseFigure();
                using (LinearGradientBrush brush = new LinearGradientBrush(bounds, BrandBlue, BrandDeepBlue, LinearGradientMode.Horizontal))
                {
                    g.FillPath(brush, blueWave);
                }
            }

            DrawPaw(g, bounds.Width - 92, 26, Color.FromArgb(32, BrandBlue));
            DrawPaw(g, bounds.Width - 48, 62, Color.FromArgb(28, BrandYellow));

            Rectangle titleRect = new Rectangle(24, 22, bounds.Width - 260, 34);
            TextRenderer.DrawText(g, "ESTAÇÃO DE TRABALHO", new Font("Segoe UI", 19F, FontStyle.Bold), titleRect, BrandBlue, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);

            Rectangle subtitleRect = new Rectangle(26, 58, bounds.Width - 260, 24);
            TextRenderer.DrawText(g, "Informações técnicas para suporte remoto", new Font("Segoe UI", 10F, FontStyle.Bold), subtitleRect, BrandRed, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);

            Rectangle chipRect = new Rectangle(bounds.Width - 246, 76, 210, 28);
            using (SolidBrush chipBrush = new SolidBrush(BrandYellow))
            {
                g.FillRectangle(chipBrush, chipRect);
            }
            TextRenderer.DrawText(g, "APAIXONADOS ITAIPUAÇU", new Font("Segoe UI", 8.5F, FontStyle.Bold), chipRect, BrandDeepBlue, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }

        private void DrawPaw(Graphics g, int x, int y, Color color)
        {
            using (SolidBrush brush = new SolidBrush(color))
            {
                g.FillEllipse(brush, x + 12, y + 20, 32, 26);
                g.FillEllipse(brush, x + 4, y + 8, 12, 14);
                g.FillEllipse(brush, x + 18, y, 12, 15);
                g.FillEllipse(brush, x + 34, y + 2, 12, 15);
                g.FillEllipse(brush, x + 48, y + 12, 12, 14);
            }
        }
    }

    internal sealed class HungProcessInfo
    {
        public int Id;
        public string Name;
        public string Title;

        public override string ToString()
        {
            string title = string.IsNullOrWhiteSpace(Title) ? "sem título" : Title;
            return string.Format("{0} (PID {1}) - {2}", Name, Id, title);
        }
    }

    internal sealed class CleanupResult
    {
        public int DeletedFiles;
        public int DeletedDirectories;
        public int SkippedItems;
        public long DeletedBytes;
        public int HungProcessesFound;
        public int HungProcessesClosed;
        public string LogPath;
        public readonly List<string> Details = new List<string>();

        public string Summary()
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("Limpeza rápida concluída.");
            sb.AppendLine();
            sb.AppendLine("Arquivos removidos: " + DeletedFiles);
            sb.AppendLine("Pastas removidas: " + DeletedDirectories);
            sb.AppendLine("Espaço liberado: " + QuickCleaner.FormatBytes(DeletedBytes));
            sb.AppendLine("Itens ignorados/em uso: " + SkippedItems);
            sb.AppendLine("Tarefas sem resposta encontradas: " + HungProcessesFound);
            sb.AppendLine("Tarefas encerradas: " + HungProcessesClosed);
            sb.AppendLine();
            sb.AppendLine("Log salvo em:");
            sb.AppendLine(LogPath);
            return sb.ToString();
        }
    }

    internal static class QuickCleaner
    {
        private const uint SHERB_NOCONFIRMATION = 0x00000001;
        private const uint SHERB_NOPROGRESSUI = 0x00000002;
        private const uint SHERB_NOSOUND = 0x00000004;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SHQUERYRBINFO
        {
            public int cbSize;
            public long i64Size;
            public long i64NumItems;
        }

        private sealed class RecycleBinSnapshot
        {
            public bool QuerySucceeded;
            public long Bytes;
            public long Items;
        }

        [DllImport("Shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHQueryRecycleBin(string pszRootPath, ref SHQUERYRBINFO pSHQueryRBInfo);

        [DllImport("Shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHEmptyRecycleBin(IntPtr hwnd, string pszRootPath, uint dwFlags);

        public static List<HungProcessInfo> FindHungProcesses()
        {
            List<HungProcessInfo> hung = new List<HungProcessInfo>();
            int currentId = Process.GetCurrentProcess().Id;

            foreach (Process process in Process.GetProcesses())
            {
                try
                {
                    if (process.Id == currentId || process.MainWindowHandle == IntPtr.Zero)
                    {
                        continue;
                    }

                    if (!process.Responding)
                    {
                        hung.Add(new HungProcessInfo
                        {
                            Id = process.Id,
                            Name = process.ProcessName,
                            Title = process.MainWindowTitle
                        });
                    }
                }
                catch
                {
                }
                finally
                {
                    try { process.Dispose(); } catch { }
                }
            }

            return hung;
        }

        public static CleanupResult Run(bool closeHungProcesses)
        {
            CleanupResult result = new CleanupResult();
            result.Details.Add("LIMPEZA RÁPIDA");
            result.Details.Add("Data: " + DateTime.Now.ToString("dd/MM/yyyy HH:mm:ss"));
            result.Details.Add("Usuário: " + WindowsIdentity.GetCurrent().Name);
            result.Details.Add("");

            CleanStandardLocations(result);
            CleanBrowserData(result);
            CleanRecycleBin(result);

            List<HungProcessInfo> hung = FindHungProcesses();
            result.HungProcessesFound = hung.Count;
            if (hung.Count > 0)
            {
                result.Details.Add("");
                result.Details.Add("Tarefas sem resposta encontradas:");
                foreach (HungProcessInfo item in hung)
                {
                    result.Details.Add("- " + item);
                }

                if (closeHungProcesses)
                {
                    CloseHungProcesses(hung, result);
                }
                else
                {
                    result.Details.Add("As tarefas sem resposta não foram encerradas por escolha do usuário.");
                }
            }

            SaveLog(result);
            return result;
        }

        private static void CleanStandardLocations(CleanupResult result)
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);

            CleanDirectoryContents(Path.GetTempPath(), "Temporários do usuário", result);
            CleanDirectoryContents(Path.Combine(local, "Temp"), "Temporários locais", result);
            CleanDirectoryContents(Path.Combine(local, @"Microsoft\Windows\INetCache"), "Cache de Internet do Windows", result);
            CleanDirectoryContents(Path.Combine(local, @"Microsoft\Windows\Temporary Internet Files"), "Arquivos temporários de Internet", result);

            if (!string.IsNullOrWhiteSpace(windows))
            {
                CleanDirectoryContents(Path.Combine(windows, "Temp"), "Temporários do Windows", result);
            }

            DeleteFilesByPattern(Path.Combine(local, @"Microsoft\Windows\Explorer"), "thumbcache_*.db", "Cache de miniaturas do Explorer", result);
            DeleteFilesByPattern(Path.Combine(local, @"Microsoft\Windows\Explorer"), "iconcache_*.db", "Cache de ícones do Explorer", result);
        }

        private static void CleanBrowserData(CleanupResult result)
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

            CleanChromiumBrowser(Path.Combine(local, @"Google\Chrome\User Data"), "Google Chrome", result);
            CleanChromiumBrowser(Path.Combine(local, @"Microsoft\Edge\User Data"), "Microsoft Edge", result);
            CleanChromiumBrowser(Path.Combine(local, @"BraveSoftware\Brave-Browser\User Data"), "Brave", result);

            CleanFirefox(Path.Combine(local, @"Mozilla\Firefox\Profiles"), Path.Combine(roaming, @"Mozilla\Firefox\Profiles"), result);
        }

        private static void CleanChromiumBrowser(string userDataPath, string browserName, CleanupResult result)
        {
            if (!Directory.Exists(userDataPath))
            {
                return;
            }

            result.Details.Add("");
            result.Details.Add(browserName + ":");

            foreach (string profile in SafeEnumerateDirectories(userDataPath))
            {
                string name = Path.GetFileName(profile);
                if (!IsBrowserProfileName(name))
                {
                    continue;
                }

                CleanDirectoryContents(Path.Combine(profile, "Cache"), browserName + " cache - " + name, result);
                CleanDirectoryContents(Path.Combine(profile, "Code Cache"), browserName + " code cache - " + name, result);
                CleanDirectoryContents(Path.Combine(profile, "GPUCache"), browserName + " GPU cache - " + name, result);
                CleanDirectoryContents(Path.Combine(profile, "Media Cache"), browserName + " media cache - " + name, result);
                CleanDirectoryContents(Path.Combine(profile, @"Service Worker\CacheStorage"), browserName + " service worker cache - " + name, result);

                DeleteFileSafe(Path.Combine(profile, @"Network\Cookies"), browserName + " cookies - " + name, result);
                DeleteFileSafe(Path.Combine(profile, @"Network\Cookies-journal"), browserName + " cookies journal - " + name, result);
                DeleteFileSafe(Path.Combine(profile, "Cookies"), browserName + " cookies legado - " + name, result);
                DeleteFileSafe(Path.Combine(profile, "Cookies-journal"), browserName + " cookies journal legado - " + name, result);
            }
        }

        private static void CleanFirefox(string localProfiles, string roamingProfiles, CleanupResult result)
        {
            CleanFirefoxCacheProfiles(localProfiles, result);
            CleanFirefoxCookieProfiles(roamingProfiles, result);
        }

        private static void CleanFirefoxCacheProfiles(string profilesPath, CleanupResult result)
        {
            if (!Directory.Exists(profilesPath))
            {
                return;
            }

            result.Details.Add("");
            result.Details.Add("Mozilla Firefox cache:");
            foreach (string profile in SafeEnumerateDirectories(profilesPath))
            {
                CleanDirectoryContents(Path.Combine(profile, "cache2"), "Firefox cache - " + Path.GetFileName(profile), result);
                CleanDirectoryContents(Path.Combine(profile, "startupCache"), "Firefox startup cache - " + Path.GetFileName(profile), result);
            }
        }

        private static void CleanFirefoxCookieProfiles(string profilesPath, CleanupResult result)
        {
            if (!Directory.Exists(profilesPath))
            {
                return;
            }

            result.Details.Add("");
            result.Details.Add("Mozilla Firefox cookies:");
            foreach (string profile in SafeEnumerateDirectories(profilesPath))
            {
                string label = "Firefox cookies - " + Path.GetFileName(profile);
                DeleteFileSafe(Path.Combine(profile, "cookies.sqlite"), label, result);
                DeleteFileSafe(Path.Combine(profile, "cookies.sqlite-wal"), label + " WAL", result);
                DeleteFileSafe(Path.Combine(profile, "cookies.sqlite-shm"), label + " SHM", result);
            }
        }

        private static void CleanRecycleBin(CleanupResult result)
        {
            result.Details.Add("");
            result.Details.Add("Lixeira:");

            RecycleBinSnapshot before = QueryRecycleBin();
            if (before.QuerySucceeded && before.Items <= 0 && before.Bytes <= 0)
            {
                result.Details.Add("- Lixeira: vazia ou sem itens acessíveis para o usuário atual.");
                return;
            }

            int emptyResult;
            try
            {
                emptyResult = SHEmptyRecycleBin(
                    IntPtr.Zero,
                    null,
                    SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND);
            }
            catch (Exception ex)
            {
                result.SkippedItems++;
                result.Details.Add("- Lixeira: não foi possível esvaziar. " + ex.Message);
                return;
            }

            if (emptyResult == 0)
            {
                if (before.QuerySucceeded)
                {
                    AddRecycleBinCounters(result, before);
                    result.Details.Add(string.Format("- Lixeira esvaziada: {0} item(ns), {1}", before.Items, FormatBytes(before.Bytes)));
                }
                else
                {
                    result.Details.Add("- Lixeira esvaziada. Não foi possível estimar quantidade e tamanho antes da limpeza.");
                }
            }
            else
            {
                result.SkippedItems++;
                result.Details.Add("- Lixeira: não foi possível esvaziar. Código: " + FormatHResult(emptyResult));
            }
        }

        private static RecycleBinSnapshot QueryRecycleBin()
        {
            RecycleBinSnapshot snapshot = new RecycleBinSnapshot();

            try
            {
                foreach (DriveInfo drive in DriveInfo.GetDrives())
                {
                    try
                    {
                        if (!drive.IsReady)
                        {
                            continue;
                        }

                        if (drive.DriveType != DriveType.Fixed &&
                            drive.DriveType != DriveType.Removable)
                        {
                            continue;
                        }

                        SHQUERYRBINFO info = new SHQUERYRBINFO();
                        info.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO));

                        int queryResult = SHQueryRecycleBin(drive.RootDirectory.FullName, ref info);
                        if (queryResult == 0)
                        {
                            snapshot.QuerySucceeded = true;
                            snapshot.Bytes += Math.Max(0, info.i64Size);
                            snapshot.Items += Math.Max(0, info.i64NumItems);
                        }
                    }
                    catch
                    {
                    }
                }
            }
            catch
            {
            }

            if (!snapshot.QuerySucceeded)
            {
                try
                {
                    SHQUERYRBINFO info = new SHQUERYRBINFO();
                    info.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO));

                    int queryResult = SHQueryRecycleBin(null, ref info);
                    if (queryResult == 0)
                    {
                        snapshot.QuerySucceeded = true;
                        snapshot.Bytes = Math.Max(0, info.i64Size);
                        snapshot.Items = Math.Max(0, info.i64NumItems);
                    }
                }
                catch
                {
                }
            }

            return snapshot;
        }

        private static void AddRecycleBinCounters(CleanupResult result, RecycleBinSnapshot snapshot)
        {
            if (snapshot.Items > 0)
            {
                long remaining = int.MaxValue - (long)result.DeletedFiles;
                if (remaining > 0)
                {
                    result.DeletedFiles += (int)Math.Min(snapshot.Items, remaining);
                }
            }

            if (snapshot.Bytes > 0)
            {
                result.DeletedBytes += snapshot.Bytes;
            }
        }

        private static string FormatHResult(int code)
        {
            return "0x" + unchecked((uint)code).ToString("X8");
        }

        private static bool IsBrowserProfileName(string name)
        {
            if (string.IsNullOrWhiteSpace(name))
            {
                return false;
            }

            return string.Equals(name, "Default", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(name, "Guest Profile", StringComparison.OrdinalIgnoreCase) ||
                   name.StartsWith("Profile", StringComparison.OrdinalIgnoreCase);
        }

        private static void CleanDirectoryContents(string path, string label, CleanupResult result)
        {
            if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
            {
                return;
            }

            int beforeFiles = result.DeletedFiles;
            int beforeDirs = result.DeletedDirectories;
            long beforeBytes = result.DeletedBytes;

            foreach (string file in SafeEnumerateFiles(path, "*", SearchOption.AllDirectories))
            {
                DeleteFileSafe(file, label, result);
            }

            List<string> directories = SafeEnumerateDirectories(path, "*", SearchOption.AllDirectories);
            directories.Sort(delegate(string a, string b) { return b.Length.CompareTo(a.Length); });

            foreach (string directory in directories)
            {
                DeleteDirectoryIfEmpty(directory, label, result);
            }

            int removedFiles = result.DeletedFiles - beforeFiles;
            int removedDirs = result.DeletedDirectories - beforeDirs;
            long removedBytes = result.DeletedBytes - beforeBytes;
            if (removedFiles > 0 || removedDirs > 0)
            {
                result.Details.Add(string.Format("- {0}: {1} arquivo(s), {2} pasta(s), {3}", label, removedFiles, removedDirs, FormatBytes(removedBytes)));
            }
        }

        private static void DeleteFilesByPattern(string path, string pattern, string label, CleanupResult result)
        {
            if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
            {
                return;
            }

            int beforeFiles = result.DeletedFiles;
            long beforeBytes = result.DeletedBytes;
            foreach (string file in SafeEnumerateFiles(path, pattern, SearchOption.TopDirectoryOnly))
            {
                DeleteFileSafe(file, label, result);
            }

            int removedFiles = result.DeletedFiles - beforeFiles;
            long removedBytes = result.DeletedBytes - beforeBytes;
            if (removedFiles > 0)
            {
                result.Details.Add(string.Format("- {0}: {1} arquivo(s), {2}", label, removedFiles, FormatBytes(removedBytes)));
            }
        }

        private static void DeleteFileSafe(string path, string label, CleanupResult result)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                return;
            }

            try
            {
                FileInfo info = new FileInfo(path);
                long length = 0;
                try { length = info.Length; } catch { }

                info.Attributes = FileAttributes.Normal;
                info.Delete();

                result.DeletedFiles++;
                result.DeletedBytes += length;
            }
            catch (Exception ex)
            {
                result.SkippedItems++;
                if (result.SkippedItems <= 80)
                {
                    result.Details.Add(string.Format("- Ignorado ({0}): {1} | {2}", label, path, ex.Message));
                }
            }
        }

        private static void DeleteDirectoryIfEmpty(string path, string label, CleanupResult result)
        {
            try
            {
                if (Directory.Exists(path) &&
                    !Directory.EnumerateFileSystemEntries(path).Any())
                {
                    Directory.Delete(path, false);
                    result.DeletedDirectories++;
                }
            }
            catch (Exception ex)
            {
                result.SkippedItems++;
                if (result.SkippedItems <= 80)
                {
                    result.Details.Add(string.Format("- Pasta ignorada ({0}): {1} | {2}", label, path, ex.Message));
                }
            }
        }

        private static List<string> SafeEnumerateFiles(string path, string pattern, SearchOption option)
        {
            List<string> files = new List<string>();
            try
            {
                files.AddRange(Directory.GetFiles(path, pattern, option));
            }
            catch
            {
                try
                {
                    files.AddRange(Directory.GetFiles(path, pattern, SearchOption.TopDirectoryOnly));
                    if (option == SearchOption.AllDirectories)
                    {
                        foreach (string directory in SafeEnumerateDirectories(path))
                        {
                            files.AddRange(SafeEnumerateFiles(directory, pattern, option));
                        }
                    }
                }
                catch
                {
                }
            }

            return files;
        }

        private static List<string> SafeEnumerateDirectories(string path)
        {
            return SafeEnumerateDirectories(path, "*", SearchOption.TopDirectoryOnly);
        }

        private static List<string> SafeEnumerateDirectories(string path, string pattern, SearchOption option)
        {
            List<string> directories = new List<string>();
            try
            {
                directories.AddRange(Directory.GetDirectories(path, pattern, option));
            }
            catch
            {
                try
                {
                    directories.AddRange(Directory.GetDirectories(path, pattern, SearchOption.TopDirectoryOnly));
                    if (option == SearchOption.AllDirectories)
                    {
                        foreach (string directory in Directory.GetDirectories(path))
                        {
                            directories.AddRange(SafeEnumerateDirectories(directory, pattern, option));
                        }
                    }
                }
                catch
                {
                }
            }

            return directories;
        }

        private static void CloseHungProcesses(List<HungProcessInfo> hung, CleanupResult result)
        {
            result.Details.Add("");
            result.Details.Add("Tentativa de encerramento de tarefas sem resposta:");

            foreach (HungProcessInfo item in hung)
            {
                try
                {
                    using (Process process = Process.GetProcessById(item.Id))
                    {
                        bool closeSent = false;
                        try { closeSent = process.CloseMainWindow(); } catch { }
                        if (closeSent)
                        {
                            process.WaitForExit(1800);
                        }

                        if (!process.HasExited)
                        {
                            process.Kill();
                            process.WaitForExit(1800);
                        }

                        if (process.HasExited)
                        {
                            result.HungProcessesClosed++;
                            result.Details.Add("- Encerrada: " + item);
                        }
                        else
                        {
                            result.SkippedItems++;
                            result.Details.Add("- Não foi possível encerrar: " + item);
                        }
                    }
                }
                catch (Exception ex)
                {
                    result.SkippedItems++;
                    result.Details.Add("- Falha ao encerrar " + item + ": " + ex.Message);
                }
            }
        }

        private static void SaveLog(CleanupResult result)
        {
            string logDirectory = null;
            try
            {
                logDirectory = Path.GetDirectoryName(typeof(QuickCleaner).Assembly.Location);
            }
            catch
            {
            }

            if (string.IsNullOrWhiteSpace(logDirectory) || !Directory.Exists(logDirectory))
            {
                logDirectory = AppDomain.CurrentDomain.BaseDirectory;
            }

            if (string.IsNullOrWhiteSpace(logDirectory) || !Directory.Exists(logDirectory))
            {
                logDirectory = Directory.GetCurrentDirectory();
            }

            if (string.IsNullOrWhiteSpace(logDirectory) || !Directory.Exists(logDirectory))
            {
                logDirectory = Path.GetTempPath();
            }

            string safeComputerName = Regex.Replace(Environment.MachineName, @"[^\w.-]", "_");
            string fileName = string.Format("Limpeza_Rapida_{0}_{1}.txt", safeComputerName, DateTime.Now.ToString("yyyyMMdd_HHmmss"));
            string path = Path.Combine(logDirectory, fileName);

            List<string> lines = new List<string>();
            lines.AddRange(result.Details);
            lines.Add("");
            lines.Add("RESUMO");
            lines.Add("Arquivos removidos: " + result.DeletedFiles);
            lines.Add("Pastas removidas: " + result.DeletedDirectories);
            lines.Add("Espaço liberado: " + FormatBytes(result.DeletedBytes));
            lines.Add("Itens ignorados/em uso: " + result.SkippedItems);
            lines.Add("Tarefas sem resposta encontradas: " + result.HungProcessesFound);
            lines.Add("Tarefas encerradas: " + result.HungProcessesClosed);

            try
            {
                File.WriteAllLines(path, lines.ToArray(), new UTF8Encoding(true));
                result.LogPath = path;
            }
            catch
            {
                path = Path.Combine(Path.GetTempPath(), fileName);
                File.WriteAllLines(path, lines.ToArray(), new UTF8Encoding(true));
                result.LogPath = path;
            }
        }

        public static string FormatBytes(long bytes)
        {
            if (bytes < 1024)
            {
                return bytes + " B";
            }

            double value = bytes / 1024.0;
            string[] units = new[] { "KB", "MB", "GB", "TB" };
            int unit = 0;
            while (value >= 1024 && unit < units.Length - 1)
            {
                value /= 1024.0;
                unit++;
            }

            return string.Format("{0:N2} {1}", value, units[unit]);
        }
    }

    internal sealed class InfoForm : Form
    {
        private readonly List<string> reportLines;
        private readonly string reportPath;
        private static readonly Color BrandBlue = Color.FromArgb(0, 70, 156);
        private static readonly Color BrandDeepBlue = Color.FromArgb(0, 54, 135);
        private static readonly Color BrandYellow = Color.FromArgb(255, 198, 0);
        private static readonly Color BrandRed = Color.FromArgb(207, 28, 35);
        private static readonly Color BrandCream = Color.FromArgb(255, 250, 242);
        private static readonly Color BrandSoftBlue = Color.FromArgb(232, 241, 255);
        private static readonly Color BrandSoftYellow = Color.FromArgb(255, 246, 204);

        public InfoForm(List<string> reportLines, string reportPath)
        {
            this.reportLines = reportLines ?? new List<string>();
            this.reportPath = reportPath;

            Text = "Informações da máquina e usuário";
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(760, 620);
            Size = new Size(900, 760);
            Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            BackColor = BrandCream;

            BuildInterface();
        }

        private void BuildInterface()
        {
            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.ColumnCount = 1;
            root.RowCount = 5;
            root.Padding = new Padding(14);
            root.BackColor = BrandCream;
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            Controls.Add(root);

            BrandHeaderPanel header = new BrandHeaderPanel();
            header.Dock = DockStyle.Top;
            header.Height = 122;
            header.Margin = new Padding(0, 0, 0, 12);
            root.Controls.Add(header, 0, 0);

            TableLayoutPanel cards = new TableLayoutPanel();
            cards.Dock = DockStyle.Top;
            cards.AutoSize = true;
            cards.ColumnCount = 2;
            cards.RowCount = 9;
            cards.CellBorderStyle = TableLayoutPanelCellBorderStyle.None;
            cards.BackColor = Color.White;
            cards.Margin = new Padding(8, 0, 8, 14);
            cards.Padding = new Padding(2);
            cards.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 220F));
            cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));

            AddField(cards, "Versão do pacote", ExtractValue("Versão do pacote"), false);
            AddField(cards, "Nome da máquina", ExtractValue("Nome da máquina"), true);
            AddField(cards, "Usuário logado", ExtractValue("Usuário logado"), true);
            AddField(cards, "Modelo", ExtractValue("Modelo"), true);
            AddField(cards, "Número de série", ExtractValue("Número de série"), true);
            AddField(cards, "IP IPv4", ExtractValue("IP IPv4"), true);
            AddField(cards, "Nome da rede", ExtractValue("Nome da rede"), true);
            AddField(cards, "Última reinicialização", ExtractValue("Última reinicialização"), true);
            AddField(cards, "Tempo sem reiniciar", ExtractValue("Tempo sem reiniciar"), true);
            root.Controls.Add(cards, 0, 1);

            TextBox fullReport = new TextBox();
            fullReport.Multiline = true;
            fullReport.ScrollBars = ScrollBars.Both;
            fullReport.ReadOnly = true;
            fullReport.WordWrap = false;
            fullReport.Dock = DockStyle.Fill;
            fullReport.Font = new Font("Consolas", 9F, FontStyle.Regular, GraphicsUnit.Point);
            fullReport.Text = string.Join(Environment.NewLine, reportLines.ToArray());
            fullReport.Margin = new Padding(8, 0, 8, 12);
            fullReport.BackColor = Color.White;
            fullReport.ForeColor = BrandDeepBlue;
            fullReport.BorderStyle = BorderStyle.FixedSingle;
            root.Controls.Add(fullReport, 0, 2);

            FlowLayoutPanel buttons = new FlowLayoutPanel();
            buttons.Dock = DockStyle.Fill;
            buttons.FlowDirection = FlowDirection.LeftToRight;
            buttons.AutoSize = true;
            buttons.WrapContents = true;
            buttons.Margin = new Padding(8, 0, 8, 0);

            Button copyButton = NewButton("Copiar informações", BrandBlue, Color.White);
            copyButton.Click += delegate
            {
                Clipboard.SetText(string.Join(Environment.NewLine, reportLines.ToArray()));
                MessageBox.Show(this, "Informações copiadas para a área de transferência.", "Copiado", MessageBoxButtons.OK, MessageBoxIcon.Information);
            };
            buttons.Controls.Add(copyButton);

            Button cleanupButton = NewButton("Limpeza rápida", BrandYellow, BrandDeepBlue);
            cleanupButton.Click += delegate
            {
                RunQuickCleanup(cleanupButton);
            };
            buttons.Controls.Add(cleanupButton);

            Button openButton = NewButton("Abrir relatório TXT", BrandYellow, BrandDeepBlue);
            openButton.Click += delegate
            {
                TryOpenReport();
            };
            buttons.Controls.Add(openButton);

            Button closeButton = NewButton("Fechar", BrandRed, Color.White);
            closeButton.Click += delegate
            {
                Close();
            };
            buttons.Controls.Add(closeButton);

            root.Controls.Add(buttons, 0, 3);

            Label path = new Label();
            path.Text = Program.IsCurrentUserAdministrator()
                ? "Relatório salvo em: " + reportPath
                : "Relatório salvo automaticamente.";
            path.Dock = DockStyle.Bottom;
            path.AutoSize = true;
            path.ForeColor = BrandDeepBlue;
            path.Margin = new Padding(8, 8, 8, 0);
            root.Controls.Add(path, 0, 4);
        }

        private void RunQuickCleanup(Button cleanupButton)
        {
            DialogResult confirm = MessageBox.Show(
                this,
                "A Limpeza rápida removerá arquivos temporários, caches, cookies dos navegadores mais comuns e o conteúdo da Lixeira.\n\n" +
                "Esvaziar a Lixeira remove arquivos de forma permanente.\n" +
                "A remoção de cookies pode deslogar sites e sistemas abertos.\n" +
                "Arquivos em uso serão ignorados.\n\n" +
                "Deseja continuar?",
                "Limpeza rápida",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);

            if (confirm != DialogResult.Yes)
            {
                return;
            }

            bool closeHungProcesses = false;
            List<HungProcessInfo> hung = QuickCleaner.FindHungProcesses();
            if (hung.Count > 0)
            {
                StringBuilder message = new StringBuilder();
                message.AppendLine("Foram encontradas tarefas sem resposta:");
                message.AppendLine();
                foreach (HungProcessInfo item in hung.Take(8))
                {
                    message.AppendLine("- " + item);
                }
                if (hung.Count > 8)
                {
                    message.AppendLine("- ... e mais " + (hung.Count - 8) + " tarefa(s).");
                }
                message.AppendLine();
                message.AppendLine("Deseja tentar encerrar essas tarefas?");
                message.AppendLine("Atenção: programas travados podem perder dados não salvos.");

                DialogResult closeConfirm = MessageBox.Show(
                    this,
                    message.ToString(),
                    "Tarefas sem resposta",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);

                closeHungProcesses = closeConfirm == DialogResult.Yes;
            }

            Cursor previousCursor = Cursor.Current;
            cleanupButton.Enabled = false;
            Cursor.Current = Cursors.WaitCursor;

            try
            {
                CleanupResult result = QuickCleaner.Run(closeHungProcesses);
                MessageBox.Show(this, result.Summary(), "Limpeza rápida", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Falha durante a Limpeza rápida: " + ex.Message, "Limpeza rápida", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                Cursor.Current = previousCursor;
                cleanupButton.Enabled = true;
            }
        }

        private void AddField(TableLayoutPanel table, string key, string value, bool highlight)
        {
            if (table.Controls.Count / 2 >= table.RowCount)
            {
                table.RowCount += 1;
            }

            Label keyLabel = new Label();
            keyLabel.Text = key;
            keyLabel.Dock = DockStyle.Fill;
            keyLabel.AutoSize = true;
            keyLabel.Padding = new Padding(10, 8, 10, 8);
            keyLabel.Margin = new Padding(0, 0, 1, 1);
            keyLabel.Font = new Font(Font.FontFamily, 9.5F, FontStyle.Bold);
            keyLabel.ForeColor = Color.White;
            keyLabel.BackColor = BrandBlue;

            Label valueLabel = new Label();
            valueLabel.Text = string.IsNullOrWhiteSpace(value) ? "Não identificado" : value;
            valueLabel.Dock = DockStyle.Fill;
            valueLabel.AutoSize = true;
            valueLabel.Padding = new Padding(10, 8, 10, 8);
            valueLabel.Margin = new Padding(0, 0, 0, 1);
            valueLabel.Font = new Font(Font.FontFamily, highlight ? 10.5F : 9.5F, highlight ? FontStyle.Bold : FontStyle.Regular);
            valueLabel.ForeColor = highlight ? BrandDeepBlue : Color.Black;
            valueLabel.BackColor = highlight ? BrandSoftYellow : Color.White;

            int nextRow = table.Controls.Count / 2;
            table.Controls.Add(keyLabel, 0, nextRow);
            table.Controls.Add(valueLabel, 1, nextRow);
        }

        private Button NewButton(string text, Color backColor, Color foreColor)
        {
            Button button = new Button();
            button.Text = text;
            button.AutoSize = true;
            button.Margin = new Padding(0, 0, 8, 0);
            button.Padding = new Padding(12, 6, 12, 6);
            button.BackColor = backColor;
            button.ForeColor = foreColor;
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderColor = backColor;
            button.Font = new Font(Font.FontFamily, 9F, FontStyle.Bold);
            return button;
        }

        private string ExtractValue(string key)
        {
            string prefix = key;
            foreach (string line in reportLines)
            {
                if (line == null)
                {
                    continue;
                }

                if (line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                {
                    int index = line.IndexOf(':');
                    if (index >= 0 && index + 1 < line.Length)
                    {
                        return line.Substring(index + 1).Trim();
                    }
                }
            }

            return "Não identificado";
        }

        private void TryOpenReport()
        {
            try
            {
                if (!string.IsNullOrWhiteSpace(reportPath) && File.Exists(reportPath))
                {
                    Process.Start(reportPath);
                }
                else
                {
                    MessageBox.Show(this, "O arquivo de relatório não foi encontrado.", "Relatório", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Não foi possível abrir o relatório: " + ex.Message, "Relatório", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}
