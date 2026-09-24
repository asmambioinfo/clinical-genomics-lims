-- 1. Create Patients Table
CREATE TABLE patients (
    patient_id INT IDENTITY(10000,1) PRIMARY KEY, -- Automatically increments: 10000, 10001, 10002...
    mrn VARCHAR(50) NOT NULL UNIQUE,
    name VARCHAR(100) NOT NULL,
    age INT NOT NULL,
    sex VARCHAR(10) NOT NULL,
    date_registered DATETIME DEFAULT GETDATE()
);

-- 2. Create Samples Table
CREATE TABLE samples (
    sample_id VARCHAR(50) PRIMARY KEY, -- Format 'SAM-XXXXXX' generated via your Python application logic
    patient_id INT FOREIGN KEY REFERENCES patients(patient_id) ON DELETE CASCADE,
    test_panel VARCHAR(100) NOT NULL,
    date_ordered DATETIME DEFAULT GETDATE(),
    status VARCHAR(20) DEFAULT 'Pending'
);

-- 3. Create Variants Table
CREATE TABLE variants (
    variant_id INT IDENTITY(1,1) PRIMARY KEY,
    sample_id VARCHAR(50) FOREIGN KEY REFERENCES samples(sample_id) ON DELETE CASCADE,
    chrom VARCHAR(5) NOT NULL,
    start_pos INT NOT NULL,
    end_pos INT NOT NULL,
    ref VARCHAR(MAX) NOT NULL,
    alt VARCHAR(MAX) NOT NULL,
    classification VARCHAR(50) NOT NULL
);
