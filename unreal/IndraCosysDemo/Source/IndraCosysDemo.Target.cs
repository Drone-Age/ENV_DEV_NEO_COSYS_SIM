// Copyright 1998-2017 Epic Games, Inc. All Rights Reserved.

using UnrealBuildTool;
using System.Collections.Generic;

public class IndraCosysDemoTarget : TargetRules
{
	public IndraCosysDemoTarget(TargetInfo Target) : base(Target)
	{
        DefaultBuildSettings = BuildSettingsVersion.V7;
        Type = TargetType.Game;
		ExtraModuleNames.AddRange(new string[] { "IndraCosysDemo" });
		//bUseUnityBuild = false;
		if (Target.Platform == UnrealTargetPlatform.Linux)
			bUsePCHFiles = false;
	}
}
