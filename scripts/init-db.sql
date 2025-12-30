-- Crear extensiones útiles
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "unaccent";

-- Tabla de empleos
CREATE TABLE IF NOT EXISTS empleos (
    id SERIAL PRIMARY KEY,
    uuid UUID DEFAULT uuid_generate_v4(),
    titulo VARCHAR(500) NOT NULL,
    empresa VARCHAR(255),
    ubicacion VARCHAR(255),
    salario VARCHAR(100),
    link VARCHAR(1000) UNIQUE NOT NULL,
    descripcion TEXT,
    portal VARCHAR(50),
    puntaje INTEGER DEFAULT 0 CHECK (puntaje >= 0 AND puntaje <= 10),
    seniority VARCHAR(20),
    tecnologias JSONB DEFAULT '[]'::jsonb,
    fecha_publicacion TIMESTAMP,
    fecha_encontrado TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    aplicado BOOLEAN DEFAULT FALSE,
    fecha_aplicacion TIMESTAMP,
    estado VARCHAR(50) DEFAULT 'pendiente',
    metadata JSONB DEFAULT '{}'::jsonb,
    search_vector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('spanish', coalesce(titulo, '')), 'A') ||
        setweight(to_tsvector('spanish', coalesce(empresa, '')), 'B') ||
        setweight(to_tsvector('spanish', coalesce(descripcion, '')), 'C')
    ) STORED
);

-- Tabla de estadísticas
CREATE TABLE IF NOT EXISTS estadisticas (
    id SERIAL PRIMARY KEY,
    fecha DATE UNIQUE NOT NULL DEFAULT CURRENT_DATE,
    total_empleos INTEGER DEFAULT 0,
    empleos_nuevos INTEGER DEFAULT 0,
    mejor_puntaje INTEGER DEFAULT 0,
    portales JSONB DEFAULT '{}'::jsonb,
    empresas_top JSONB DEFAULT '{}'::jsonb,
    tecnologias_demandadas JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Tabla de configuraciones
CREATE TABLE IF NOT EXISTS configuraciones (
    id SERIAL PRIMARY KEY,
    clave VARCHAR(100) UNIQUE NOT NULL,
    valor JSONB NOT NULL,
    descripcion TEXT,
    actualizado TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    actualizado_por VARCHAR(100) DEFAULT 'system'
);

-- Índices para performance
CREATE INDEX IF NOT EXISTS idx_empleos_puntaje ON empleos(puntaje DESC);
CREATE INDEX IF NOT EXISTS idx_empleos_portal ON empleos(portal);
CREATE INDEX IF NOT EXISTS idx_empleos_fecha ON empleos(fecha_encontrado DESC);
CREATE INDEX IF NOT EXISTS idx_empleos_tecnologias ON empleos USING gin(tecnologias);
CREATE INDEX IF NOT EXISTS idx_empleos_aplicado ON empleos(aplicado, estado);
CREATE INDEX IF NOT EXISTS idx_empleos_seniority ON empleos(seniority);
CREATE INDEX IF NOT EXISTS idx_empleos_search ON empleos USING GIN(search_vector);

-- Índice para búsqueda por texto
CREATE INDEX IF NOT EXISTS idx_empleos_texto ON empleos USING GIST (
    (unaccent(titulo || ' ' || empresa || ' ' || descripcion)) gist_trgm_ops
);

-- Vista para dashboard
CREATE OR REPLACE VIEW vista_dashboard AS
SELECT 
    DATE_TRUNC('day', fecha_encontrado) as fecha,
    portal,
    COUNT(*) as total,
    AVG(puntaje)::NUMERIC(4,2) as puntaje_promedio,
    SUM(CASE WHEN aplicado THEN 1 ELSE 0 END) as aplicados,
    COUNT(DISTINCT empresa) as empresas_unicas
FROM empleos
WHERE fecha_encontrado > CURRENT_DATE - INTERVAL '30 days'
GROUP BY DATE_TRUNC('day', fecha_encontrado), portal
ORDER BY fecha DESC, total DESC;

-- Función para limpiar empleos antiguos
CREATE OR REPLACE FUNCTION limpiar_empleos_antiguos(dias INTEGER DEFAULT 30)
RETURNS INTEGER AS $$
DECLARE
    eliminados INTEGER;
BEGIN
    DELETE FROM empleos 
    WHERE fecha_encontrado < NOW() - INTERVAL '1 day' * dias
    AND aplicado = FALSE
    AND puntaje < 5
    AND fecha_encontrado < NOW() - INTERVAL '7 days';
    
    GET DIAGNOSTICS eliminados = ROW_COUNT;
    
    -- Registrar en log
    INSERT INTO configuraciones (clave, valor, descripcion)
    VALUES ('limpieza_automatica', 
            jsonb_build_object(
                'fecha', NOW(),
                'eliminados', eliminados,
                'dias', dias
            ),
            'Limpieza automática de empleos antiguos')
    ON CONFLICT (clave) DO UPDATE SET
        valor = EXCLUDED.valor,
        actualizado = NOW();
    
    RETURN eliminados;
END;
$$ LANGUAGE plpgsql;

-- Función para buscar empleos
CREATE OR REPLACE FUNCTION buscar_empleos(
    p_query TEXT DEFAULT NULL,
    p_portal TEXT[] DEFAULT NULL,
    p_min_puntaje INTEGER DEFAULT 0,
    p_max_puntaje INTEGER DEFAULT 10,
    p_dias INTEGER DEFAULT 30
)
RETURNS TABLE (
    id INTEGER,
    titulo VARCHAR,
    empresa VARCHAR,
    ubicacion VARCHAR,
    puntaje INTEGER,
    portal VARCHAR,
    link VARCHAR,
    fecha_encontrado TIMESTAMP,
    relevancia FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        e.id,
        e.titulo,
        e.empresa,
        e.ubicacion,
        e.puntaje,
        e.portal,
        e.link,
        e.fecha_encontrado,
        CASE 
            WHEN p_query IS NOT NULL THEN 
                ts_rank(e.search_vector, websearch_to_tsquery('spanish', p_query))
            ELSE 1.0
        END as relevancia
    FROM empleos e
    WHERE 
        (p_query IS NULL OR e.search_vector @@ websearch_to_tsquery('spanish', p_query))
        AND (p_portal IS NULL OR e.portal = ANY(p_portal))
        AND e.puntaje BETWEEN p_min_puntaje AND p_max_puntaje
        AND e.fecha_encontrado > NOW() - INTERVAL '1 day' * p_dias
    ORDER BY relevancia DESC, e.puntaje DESC, e.fecha_encontrado DESC
    LIMIT 100;
END;
$$ LANGUAGE plpgsql;

-- Insertar configuración inicial
INSERT INTO configuraciones (clave, valor, descripcion) VALUES
('perfil_usuario', '{
    "nombre": "Desarrollador Python",
    "email": "tu@email.com",
    "telefono": "+51987654321",
    "keywords": ["python", "backend", "django", "fastapi", "aws", "docker", "kubernetes", "postgresql"],
    "excluir": ["jr", "trainee", "pasante", "estudiante", "sin experiencia"],
    "seniority_deseado": ["mid", "senior"],
    "salario_minimo": 3500,
    "ubicaciones": ["remoto", "lima", "perú", "latam"],
    "modalidad": ["remoto", "hibrido"]
}', 'Perfil de búsqueda del usuario'),

('portales_config', '{
    "computrabajo": {
        "url_base": "https://www.computrabajo.com.pe",
        "intervalo_busqueda": 6,
        "activo": true,
        "pais": "peru"
    },
    "linkedin": {
        "url_base": "https://www.linkedin.com/jobs",
        "intervalo_busqueda": 4,
        "activo": true,
        "pais": "global"
    },
    "indeed": {
        "url_base": "https://pe.indeed.com",
        "intervalo_busqueda": 6,
        "activo": true,
        "pais": "peru"
    },
    "getonbrd": {
        "url_base": "https://www.getonbrd.com",
        "intervalo_busqueda": 8,
        "activo": true,
        "pais": "latam"
    }
}', 'Configuración de portales de empleo'),

('ia_config', '{
    "modelo": "gpt-3.5-turbo",
    "temperature": 0.3,
    "max_tokens": 500,
    "habilitado": true,
    "criterios_evaluacion": ["relevancia_tecnica", "seniority", "salario_estimado", "match_con_perfil"]
}', 'Configuración de IA para análisis de empleos'),

('notificaciones', '{
    "telegram": {
        "activo": false,
        "token": "",
        "chat_id": ""
    },
    "email": {
        "activo": false,
        "smtp_host": "",
        "smtp_port": 587,
        "email_from": ""
    },
    "umbral_puntaje": 7,
    "frecuencia": "diaria"
}', 'Configuración de notificaciones'),

('sistema', '{
    "version": "1.0.0",
    "ultima_actualizacion": "2024-01-01",
    "mantenimiento_automatico": true,
    "backup_automatico": true
}', 'Configuración del sistema');

-- Crear trigger para actualizar estadísticas
CREATE OR REPLACE FUNCTION actualizar_estadisticas()
RETURNS TRIGGER AS $$
BEGIN
    -- Actualizar estadísticas del día
    INSERT INTO estadisticas (fecha, total_empleos, empleos_nuevos)
    VALUES (CURRENT_DATE, 1, 1)
    ON CONFLICT (fecha) DO UPDATE SET
        total_empleos = estadisticas.total_empleos + 1,
        empleos_nuevos = estadisticas.empleos_nuevos + 1,
        mejor_puntaje = GREATEST(estadisticas.mejor_puntaje, COALESCE(NEW.puntaje, 0));
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_actualizar_estadisticas
AFTER INSERT ON empleos
FOR EACH ROW
EXECUTE FUNCTION actualizar_estadisticas();

-- Insertar datos de prueba (opcional)
INSERT INTO empleos (titulo, empresa, ubicacion, portal, puntaje, link) VALUES
('Desarrollador Python Senior', 'TechCorp', 'Lima, Remoto', 'computrabajo', 9, 'https://computrabajo.com.pe/job1'),
('Backend Developer', 'StartupXYZ', 'Remoto', 'linkedin', 8, 'https://linkedin.com/job2'),
('Python Django Developer', 'EmpresaABC', 'Lima', 'indeed', 7, 'https://indeed.com/job3')
ON CONFLICT (link) DO NOTHING;

-- Mensaje de éxito
DO $$ 
BEGIN
    RAISE NOTICE '✅ Base de datos Job Hunter inicializada correctamente';
    RAISE NOTICE '📊 Tablas creadas: empleos, estadisticas, configuraciones';
    RAISE NOTICE '🔍 Índices optimizados para búsqueda';
    RAISE NOTICE '🤖 Funciones y triggers configurados';
END $$;