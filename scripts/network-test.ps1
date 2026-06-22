param (
    [string]$targets,
    [string]$selfIp
)

# Exit if no targets
if ([string]::IsNullOrEmpty($targets)) {
    exit
}

# Convert to array
$targetList = $targets.Split(',')

# Create folder
New-Item -Path C:\temp -ItemType Directory -Force

# Start log
"Starting network test" | Out-File C:\temp\network-test.txt

# Run tests
foreach ($t in $targetList) {
    if ($t -ne $selfIp) {
        Test-NetConnection -ComputerName $t -Port 3389 |
        Out-File -Append C:\temp\network-test.txt
    }
}