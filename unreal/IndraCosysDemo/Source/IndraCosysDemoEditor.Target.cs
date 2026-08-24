// Copyright 1998-2017 Epic Games, Inc. All Rights Reserved.

using UnrealBuildTool;
using System.Collections.Generic;

public class IndraCosysDemoEditorTarget : TargetRules
{
	public IndraCosysDemoEditorTarget(TargetInfo Target) : base(Target)
	{
	    DefaultBuildSettings = BuildSettingsVersion.V7;
        Type = TargetType.Editor;
		ExtraModuleNames.AddRange(new string[] { "IndraCosysDemo" });
        IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
        //bUseUnityBuild = false;
        //bUsePCHFiles = false;
    }
}
