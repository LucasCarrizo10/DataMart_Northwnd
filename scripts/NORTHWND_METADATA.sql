USE master
GO

IF EXISTS(SELECT NAME FROM SYS.databases WHERE NAME='NORTHWND_METADATA')
BEGIN
	DROP DATABASE NORTHWND_METADATA
END
GO

CREATE DATABASE NORTHWND_METADATA
GO

USE NORTHWND_METADATA
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[ETLExecution](
	[ID] [int] IDENTITY(1,1) NOT NULL,
	[UserName] [nvarchar](50) NULL,
	[MachineName] [nvarchar](50) NULL,
	[PackageName] [nvarchar](50) NULL,
	[ETLLoad] [datetime] NULL,
	[ETLCountRows] [bigint] NULL,
	[ETLCountNewRegister] [bigint] NULL,
	[ETLCountModifiedRegister] [bigint] NULL
) ON [PRIMARY]
GO