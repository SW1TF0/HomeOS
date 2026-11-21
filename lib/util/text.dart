/// "1 device", "3 devices".
String counted(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
