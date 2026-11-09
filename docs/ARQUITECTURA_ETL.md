# Arquitectura y decisiones técnicas — Data Mart Northwind

[← Volver al README](../README.md)

Este documento amplía los detalles de implementación del [resumen principal](../README.md), sin repetir la presentación del proyecto. Se elaboró a partir de los **21 paquetes `.dtsx`**, los **21 scripts SQL** de Load, Stage y Data Mart, el script de metadatos y las consultas/capturas de SQL Server compartidas durante el desarrollo. Las cifras son resultados observados en las tablas; no se realizó una nueva ejecución independiente de todos los paquetes.

## 1. Responsabilidades y recorrido

| Etapa | Entrada | Transformación / objetivo | Salida |
| --- | --- | --- | --- |
| **Load** | Tablas operativas Northwind | Extracción y columnas `ETLLoad` / `ETLExecution` | `LOAD_NORTHWND` |
| **Stage** | Registros seleccionados desde Load | Preparación de entidades, ventas y calendario; limpieza de tablas intermedias | `STAGE_NORTHWND` |
| **Data Mart** | Tablas de Stage | Búsqueda de claves, comparación de cambios e inserción/actualización | `DATAMART_NORTHWND` |
| **Metadata** | Eventos de paquetes SSIS | Inserciones y actualizaciones de conteos de ejecución | `NORTHWND_METADATA.dbo.ETLExecution` |

La selección de ejecuciones de Load se apoya en `ETLExecution` (en varios scripts se consulta el `MAX(ETLExecution)`). Por eso es clave **distinguir filas almacenadas históricamente de filas de la carga seleccionada**.

## 2. Orquestación de paquetes

Los tres proyectos reúnen siete paquetes cada uno (un maestro más seis unidades de trabajo):

| Proyecto | Maestro | Paquetes especializados |
| --- | --- | --- |
| Load | `LoadMaster.dtsx` | `LoadEmployee`, `LoadProducts`, `LoadCategorie`, `LoadCustomer`, `LoadOrder`, `LoadOrderDetails` |
| Stage | `StageMaster.dtsx` | `Stage_Empleado`, `Stage_Producto`, `Stage_Categories`, `Stage_Cliente`, `Stage_Ventas`, `Stage_Tiempo` |
| Data Mart | `DataMartMaster.dtsx` | `DimEmpleado`, `DimCategoria`, `DimProducto`, `DimCliente`, `DimTiempo`, `FactVentas` |

Las tareas **Execute Package Task** y sus restricciones de precedencia coordinan el orden. En el Data Mart, `FactVentas` se ejecuta después de las dimensiones para poder resolver las claves de referencia.

<details>
<summary>Ver orquestación de Load y Stage</summary>

![LoadMaster](../images/load-master.png)

![StageMaster](../images/stage-master.png)

</details>

![DataMartMaster](../images/datamart-master.png)

## 3. Transformaciones por etapa

### Load: incorporación del origen y contexto de ejecución

Se cargan `Employees`, `Products`, `Categories`, `Customers`, `Orders` y `Order Details`. Los paquetes utilizan fuentes/destinos OLE DB, **Derived Column** y **Row Count**; las columnas de trazabilidad permiten asociar las filas a cargas específicas.

**Evidencia de la conservación por ejecución:** `Categories` registraba 56 filas. Una agrupación por `CategoryID` devolvió ocho identificadores distintos, cada uno presente siete veces y asociado a siete `ETLExecution` diferentes. Esto es consistente con siete cargas acumuladas; no debe confundirse con 56 categorías de negocio.

### Stage: información preparada para el modelo

Se generan las tablas `Stage_Empleado`, `Stage_Producto`, `Stage_Categoria`, `Stage_Cliente`, `Stage_Ventas` y `Stage_Tiempo`. En los scripts aparecen normalizaciones de tipo de dato (por ejemplo, identificador de cliente), combinaciones de órdenes con su detalle y atributos derivados de fecha.

Las tareas de control incluyen limpieza de staging, referencias a la ejecución de Load y registro de conteos. Existen también tablas auxiliares con sufijo `_Mod` utilizadas en el tratamiento de modificaciones de la fase dimensional.

### Data Mart: modelo de análisis

| Tabla | Perspectiva analítica |
| --- | --- |
| `Dim_Categoria` | Clasificación de productos |
| `Dim_Cliente` | Cliente |
| `Dim_Empleado` | Responsable/empleado |
| `Dim_Producto` | Producto y atributos asociados |
| `Dim_Tiempo` | Fecha y atributos de calendario |
| `Fact_Ventas` | Hechos de ventas, cantidades, precios, descuentos y referencias dimensionales |

Las dimensiones tienen claves sustitutas `SKey`. `Fact_Ventas` identifica las referencias a cliente, empleado, producto y tiempo mediante búsquedas de dimensiones y conserva datos de pedidos y medidas. El script utiliza el número de orden y las claves dimensionales para identificar coincidencias; conviene tratar la combinación exacta como **clave lógica utilizada por el proceso**, sin afirmar que haya una restricción física de unicidad no verificada.

## 4. Tratamiento de registros nuevos y modificados

En los paquetes de dimensiones y en `FactVentas.dtsx` se observan componentes de comparación y bifurcación de flujos. El recorrido de `FactVentas` incluye:

1. Lectura de registros desde Stage y desde el Data Mart.
2. Obtención de valores `StageMD5` y `DataMartMD5`, seguida de `Merge Join`.
3. `Conditional Split` para encaminar **registros nuevos** y **registros modificados**.
4. `Lookup` contra las dimensiones en ambas rutas.
5. `Row Count` y operaciones OLE DB de inserción/actualización.

![Transformaciones de FactVentas](../images/fact-ventas-flujo.png)

La comparación por hash permite detectar diferencias entre representaciones de registros. **No se presenta como SCD Tipo 2**: los scripts muestran principalmente actualización de valores existentes y no se ha identificado una estrategia completa de versionado histórico de dimensiones.

## 5. Auditoría y observabilidad

`NORTHWND_METADATA.dbo.ETLExecution` contiene:

| Campo | Información registrada |
| --- | --- |
| `ID` | Identificador de registro de ejecución |
| `UserName`, `MachineName` | Contexto de ejecución |
| `PackageName` | Nombre del paquete |
| `ETLLoad` | Fecha y hora |
| `ETLCountRows` | Filas contabilizadas |
| `ETLCountNewRegister` | Registros nuevos |
| `ETLCountModifiedRegister` | Registros modificados |

En los `.dtsx` hay **Execute SQL Task** para insertar la ejecución, recuperar su `ID` y actualizar contadores. Las capturas de `ETLExecution` muestran registros efectivos de distintos paquetes, con conteos poblados en algunas filas y `NULL` en otras. Por eso, la auditoría **existe y se usa**, pero los conteos no están completos en todas las ejecuciones registradas.

**Precauciones al reutilizar la solución:** el script de metadatos elimina y recrea la base si ya existe (`DROP DATABASE`). Además, obtener `TOP(1) ID ... ORDER BY ID DESC` filtrando por paquete puede ser ambiguo si dos instancias del mismo paquete se ejecutan simultáneamente. En un entorno productivo convendría correlacionar por un ID de ejecución propagado entre tareas y evitar scripts destructivos.

## 6. Conteos verificados en capturas de SQL Server

Los valores siguientes reflejan un **estado concreto de las tablas**; no son métricas de rendimiento ni equivalen necesariamente a una sola corrida.

### LOAD_NORTHWND

| Tabla | Filas |
| --- | ---: |
| `Categories` | 56 |
| `Customers` | 546 |
| `Employees` | 90 |
| `Order Details` | 12.930 |
| `Orders` | 4.980 |
| `Products` | 616 |

### STAGE_NORTHWND

| Tabla | Filas |
| --- | ---: |
| `Stage_Categoria` | 8 |
| `Stage_Cliente` | 91 |
| `Stage_Empleado` | 9 |
| `Stage_Producto` | 77 |
| `Stage_Tiempo` | 480 |
| `Stage_Ventas` | 2.155 |

Tablas auxiliares observadas: `Dim_Categoria_Mod` (1), `Dim_Cliente_Mod` (14), `Dim_Empleado_Mod` (65), `Dim_Producto_Mod` (1) y `Fact_Ventas_Mod` (0). No forman parte del volumen analítico principal.

### DATAMART_NORTHWND

| Tabla | Filas |
| --- | ---: |
| `Dim_Categoria` | 8 |
| `Dim_Cliente` | 91 |
| `Dim_Empleado` | 9 |
| `Dim_Producto` | 77 |
| `Dim_Tiempo` | 480 |
| `Fact_Ventas` | 2.155 |

La tabla de sistema `sysdiagrams` (1 fila) se excluye de los resultados funcionales.


## Resultados del procesamiento ETL

El proceso ETL fue diseñado para transformar los datos transaccionales de Northwind en un modelo dimensional orientado al análisis de ventas.

### Procesamiento por etapas

**LOAD_NORTHWND — Extracción y trazabilidad**

Centraliza los datos provenientes de Northwind e incorpora identificadores de ejecución y marcas temporales. Esto permite relacionar los registros cargados con las ejecuciones de los paquetes SSIS.

**STAGE_NORTHWND — Preparación de datos**

Organiza y transforma la información necesaria para alimentar el modelo dimensional. En esta etapa se identificaron 2.155 líneas de venta correspondientes a 830 órdenes distintas.

**DATAMART_NORTHWND — Modelo analítico**

Integra las dimensiones y la tabla de hechos para permitir el análisis de ventas por cliente, empleado, producto, categoría y período.

El volumen de referencia para una carga consolidada es de 2.155 líneas de venta y 9 empleados del conjunto original de Northwind.

### Auditoría y trazabilidad

La base `NORTHWND_METADATA` permite registrar información sobre las ejecuciones de los paquetes ETL, incluyendo el usuario, equipo, fecha, paquete ejecutado y cantidades procesadas.

Esta separación facilita el seguimiento del pipeline y mantiene los metadatos de ejecución independientes de la información destinada al análisis.

### Valor de la solución

La arquitectura implementada separa las responsabilidades de extracción, transformación, almacenamiento analítico y auditoría.

El resultado es un proceso de integración estructurado, con componentes reutilizables y un modelo dimensional diseñado para facilitar futuras consultas, indicadores y visualizaciones de negocio.


## 7. Validaciones recomendadas antes de usarlo para reportes

Estas verificaciones ayudan a distinguir un pipeline funcional de un conjunto de indicadores confiables:

- Conciliar filas por `ETLExecution` y clave de negocio, en vez de comparar solo conteos globales.
- Verificar unicidad lógica de `Fact_Ventas` por la combinación de claves y número de orden definida en los scripts.
- Revisar la expresión de importe `UnitPrice * Quantity - Discount` en el script de staging: en el modelo Northwind habitual `Discount` es una **fracción**, por lo que la lógica de negocio debe confirmarse antes de calcular ingresos definitivos.
- Comprobar claves dimensionales faltantes, registros no asociados y consistencia de medidas.
- En una nueva ejecución controlada, comparar conteos de entradas, altas, modificaciones y salidas con `ETLExecution`.

Estas son recomendaciones de control de calidad **y no funcionalidades adicionales que se atribuyan al proyecto**.

## 8. Reproducción y limitaciones del entorno

1. Contar con SQL Server, Visual Studio y un proyecto de Integration Services compatible.
2. Restaurar el origen Northwind y crear las bases de trabajo correspondientes (revisar scripts destructivos antes de ejecutarlos).
3. Configurar administradores de conexión, variables, rutas y permisos según el equipo.
4. Ejecutar y validar por etapas: `LoadMaster` → `StageMaster` → `DataMartMaster`.
5. Revisar `ETLExecution`, totales y conciliaciones posteriores.

Los `.dtsx` y scripts permiten inspeccionar la implementación. Las capturas aportan **evidencia de tablas pobladas y de ejecuciones registradas**; no se pretende que esta documentación sustituya pruebas reproducibles con un conjunto controlado de datos.
