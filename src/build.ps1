param (
    [Parameter(Mandatory=$true)]
    [int]
    $ModPackId,
    [Parameter(Mandatory=$true)]
    [int]
    $ModVersion,
    [Parameter(Mandatory=$true)]
    [string]
    $ContainerName,
    [Parameter(Mandatory=$true)]
    [string]
    $DockerTag
)

$fullContainerName = "$ContainerName`:$DockerTag"

 Write-Host $fullContainerName
docker build --pull --rm -f "Dockerfile" --build-arg MODPACK_ID=$ModPackId --build-arg MODPACK_VERSION=$ModVersion -t $fullContainerName "."